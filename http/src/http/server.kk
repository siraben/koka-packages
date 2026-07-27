/* An HTTP/1.1 server.

   One task per connection, inside a task group, so a connection cannot outlive
   the server and the server cannot return while a connection is still being
   handled.

   ## What is bounded

   Everything.  A connection that misbehaves costs a bounded amount:

   * the accept loop stops at `max-connections` concurrent connections;
   * a read is at most `read-chunk` octets;
   * the buffered request may not exceed the message limits (request line,
     header block, body), and the check happens while reading, not after;
   * a request has `request-timeout-ms` to arrive in full;
   * an idle keep-alive connection is closed after `idle-timeout-ms`;
   * a connection serves at most `max-requests` requests before closing;
   * one request may be assembled from at most `max-reads` socket reads, which
     bounds the repeated buffer join: a client dribbling a megabyte one octet
     at a time would otherwise cost O(n^2) in the request size.

   No user-level queue is unbounded: the accept loop is the only producer and
   it stops producing when the connection count is at the limit, and the
   channels between tasks are bounded.  The libuv completion queue is a
   linked list with no explicit cap -- it is bounded in practice by the number
   of requests outstanding, which the limits above bound in turn.

   ## Shutdown

   `stop` makes the accept loop stop accepting and cancels the group.  Handlers
   in flight are cancelled at their next suspension point and unwind through
   their cleanup, so sockets and database statements are released.  `serve`
   returns only after that has happened.

   ## Logging

   The server logs one record per completed request, with the request id, the
   method, the path, the status and the duration.  The logger handler is
   installed *inside each connection task*, with the request id already in its
   context, so anything a handler logs carries the id without the handler doing
   anything.

   It is installed per connection rather than around the whole server because
   `spawn` fixes a task's effect row to `<async|io>`: a task cannot inherit an
   ambient `logger` from its parent.  The server therefore takes the logging
   configuration as plain values and installs the handler where the row is
   under its control.
*/
module http/server

import bytes/bytes
import runtime/loop
import runtime/task
import runtime/net
import logging/log
import http/message
import http/router

pub struct config
  host               : string
  port               : int
  // Concurrent connections.  The accept loop pauses at this number.
  max-connections    : int
  // How long a complete request has to arrive.
  request-timeout-ms : int
  // How long an idle keep-alive connection is held open.
  idle-timeout-ms    : int
  // Requests served on one connection before it is closed.
  max-requests       : int
  // Socket reads one request may be assembled from.
  max-reads          : int
  read-chunk         : int
  limits             : limits
  backlog            : int

pub val default-config : config
  = Config("127.0.0.1", 8080, 256, 15000, 30000, 100, 1024, 65536, default-limits, 128)

// Check the invariants the serving loops rely on.
//
// In particular, `max-connections <= 0` used to make the accept loop sleep
// forever without accepting, while `max-reads <= 0` made every request fail
// before its first read.  Configuration mistakes should fail at startup, not
// masquerade as an unresponsive server.
pub fun validate-config( cfg : config ) : maybe<string>
  if cfg.host.is-empty then Just("host must not be empty")
  elif cfg.port < 0 || cfg.port > 65535 then Just("port must be between 0 and 65535")
  elif cfg.max-connections <= 0 then Just("max-connections must be positive")
  elif cfg.request-timeout-ms <= 0 then Just("request-timeout-ms must be positive")
  elif cfg.idle-timeout-ms <= 0 then Just("idle-timeout-ms must be positive")
  elif cfg.max-requests <= 0 then Just("max-requests must be positive")
  elif cfg.max-reads <= 0 then Just("max-reads must be positive")
  elif cfg.read-chunk <= 0 then Just("read-chunk must be positive")
  elif cfg.backlog <= 0 then Just("backlog must be positive")
  elif cfg.limits.max-request-line <= 0 then Just("max-request-line must be positive")
  elif cfg.limits.max-header-bytes < 0 then Just("max-header-bytes must not be negative")
  elif cfg.limits.max-headers < 0 then Just("max-headers must not be negative")
  elif cfg.limits.max-body < 0 then Just("max-body must not be negative")
  else Nothing

// How the server logs.  Passed as values because the logger handler is
// installed per connection; see the module header.
pub struct log-config
  emit  : (string) -> <async|io> ()
  min   : level
  base  : list<field>

pub val default-log-config : log-config
  = Log-config(fn(l) println(l), Info, [])

// A running server, so a caller can find the port and ask it to stop.
pub struct server
  group    : task-group
  bound    : int
  stopping : ref<global, bool>

pub fun port( s : server ) : int
  s.bound

// Ask the server to stop accepting and cancel in-flight work.
pub fun stop( s : server ) : io ()
  val f = s.stopping
  f := True
  s.group.cancel

fun is-stopping( s : server ) : io bool
  val f = s.stopping
  !f

// ----------------------------------------------------------------------------
// serving
// ----------------------------------------------------------------------------

// Run a server until `ready` decides to stop it.
//
// `ready` is called once with the running server, which is how a test learns
// the port and how a signal handler gets something to call `stop` on.  When
// `ready` returns, the server shuts down.
pub fun serve( serve-request : (request) -> <async,logger|io> response,
               ready : (server) -> <async|io> (),
               cfg : config = default-config,
               logs : log-config = default-log-config ) : io ()
  match cfg.validate-config
    Just(msg) -> throw("invalid HTTP server configuration: " ++ msg)
    Nothing  -> serve-valid(serve-request, ready, cfg, logs)

fun serve-valid( serve-request : (request) -> <async,logger|io> response,
                 ready : (server) -> <async|io> (),
                 cfg : config, logs : log-config ) : io ()
  // The listener is managed explicitly rather than with `with-listener`.
  // `finally` around a computation that drives the task scheduler closed the
  // listening socket while the server was still running; the scheduler runs
  // handler continuations underneath, and that is enough to make `finally`
  // decide the computation ended.  An explicit close on both exits is
  // unambiguous.
  val l = net/listen(cfg.host, cfg.port, cfg.backlog)
  match try({ serve-on(l, serve-request, ready, cfg, logs) })
    Ok(_)     -> listener/close(l)
    Error(ex) -> { listener/close(l); throw-exn(ex) }

fun serve-on( l : listener, serve-request : (request) -> <async,logger|io> response,
              ready : (server) -> <async|io> (),
              cfg : config, logs : log-config ) : io ()
  // Stopping cancels every task in the group, including the root, so the root
  // raises on its way out.  That is the server shutting itself down, not a
  // failure, and it must not escape to the caller.
  match try({ run-group(l, serve-request, ready, cfg, logs) })
    Ok(_)     -> ()
    Error(ex) -> if is-cancellation(ex) then () else throw-exn(ex)

fun run-group( l : listener, serve-request : (request) -> <async,logger|io> response,
               ready : (server) -> <async|io> (),
               cfg : config, logs : log-config ) : io ()
  val bound = l.port
  with-task-group fn(g)
    val srv = Server(g, bound, ref(False))
    with-json-logger((logs.emit), { info("server listening",
                                         [("host", cfg.host), int/field("port", bound)]) },
                     logs.min, logs.base)
    spawn(fn() accept-loop(l, srv, serve-request, cfg, logs))
    ready(srv)
    srv.stop
    with-json-logger((logs.emit), { info("server stopped", []) }, logs.min, logs.base)

// Accept until the server is stopped, holding at most `max-connections` open.
fun accept-loop( l : listener, srv : server,
                 serve-request : (request) -> <async,logger|io> response,
                 cfg : config, logs : log-config ) : <async|io> ()
  val live = ref(0)
  accept-next(l, srv, serve-request, cfg, logs, live)

fun accept-next( l : listener, srv : server,
                 serve-request : (request) -> <async,logger|io> response,
                 cfg : config, logs : log-config, live : ref<global,int> ) : <async|io> ()
  if srv.is-stopping then ()
  else
    // Backpressure on accept: while at the limit, wait rather than queue.
    if live-count(live) >= cfg.max-connections then
      sleep(5)
      accept-next(l, srv, serve-request, cfg, logs, live)
    else
      // A plain blocking accept, not a poll with a deadline.  Polling raced the
      // timer against the accept: when both completed in the same turn and the
      // timer was drained first, the connection that had already been accepted
      // in C had no task to own it and was stranded.  Cancellation is what
      // stops this loop -- `stop` cancels the group, which wakes the parked
      // accept -- so a deadline buys nothing.
      val sock = accept(l)
      adjust(live, 1)
      spawn(fn() run-connection(sock, serve-request, cfg, logs, live))
      accept-next(l, srv, serve-request, cfg, logs, live)

// Named for what it counts: this module also counts socket *reads*, and
// `read-count` read as that.
fun live-count( r : ref<global,int> ) : io int
  !r

fun adjust( r : ref<global,int>, n : int ) : io ()
  r := !r + n

// ----------------------------------------------------------------------------
// one connection
// ----------------------------------------------------------------------------

// One connection's failure must not take the server with it.
//
// A task that throws makes its group cancel every sibling, which for a server
// means one bad connection shutting down the listener.  Anything that escapes
// a connection is therefore contained here and logged; only a cancellation --
// the server itself shutting down -- is allowed to propagate.
fun run-connection( sock : socket,
                    serve-request : (request) -> <async,logger|io> response,
                    cfg : config, logs : log-config, live : ref<global,int> ) : <async|io> ()
  defer({ adjust(live, -1) })
  match try({ with-socket(sock, fn(s) connection-loop(s, serve-request, cfg, logs, bytes-empty, 0)) })
    Ok(_) -> ()
    Error(ex) ->
      if is-cancellation(ex) then throw-exn(ex)
      else
        with-json-logger((logs.emit),
                         { warn("connection failed", [("error", ex.message)]) },
                         logs.min, logs.base)

fun connection-loop( s : socket, serve-request : (request) -> <async,logger|io> response,
                     cfg : config, logs : log-config,
                     buffered : bytes, served : int ) : <async|io> ()
  if served >= cfg.max-requests then ()
  else
    match read-request(s, cfg, buffered, now-ms() + cfg.request-timeout-ms, served == 0)
      ReadClosed -> ()
      ReadFailed(err) ->
        // Answer with the status the parser chose and close; a client that
        // sent something we could not parse does not get keep-alive.
        send-response(s, response(err.status, bytes(err.message),
                                  [("content-type", "text/plain; charset=utf-8")]), False)
        ()
      ReadOk(req, rest) ->
        val rid = "r" ++ fresh-request().show
        val started = now-ms()
        val resp = with-json-logger((logs.emit),
                                    { run-handler(serve-request, req) },
                                    logs.min, logs.base ++ [("request-id", rid)])
        val keep = req.wants-keep-alive && served + 1 < cfg.max-requests
        send-response(s, resp, keep)
        with-json-logger((logs.emit),
                         { info("request", [ ("method", req.method)
                                           , ("path", req.path)
                                           , int/field("status", resp.status)
                                           , int/field("duration-ms", now-ms() - started) ]) },
                         logs.min, logs.base ++ [("request-id", rid)])
        if keep then connection-loop(s, serve-request, cfg, logs, rest, served + 1)

// A handler that throws must not take the connection with it.
fun run-handler( serve-request : (request) -> <async,logger|io> response,
                 req : request ) : <async,logger|io> response
  match try({ serve-request(req) })
    Ok(r) -> r
    Error(ex) ->
      if is-cancellation(ex) then throw-exn(ex)   // shutdown: let it propagate
      else
        error("handler failed", [("error", ex.message)])
        json-response(500, "{\"error\":\"internal server error\"}")

type read-result
  ReadOk( request : request, rest : bytes )
  ReadClosed
  ReadFailed( error : parse-error )

// Read until a complete request has arrived or a limit or deadline is hit.
//
// `scanned` is how much of `buffered` has already been searched for the end of
// the head, and `reads` counts how many times we have gone back to the socket.
// Both exist to bound a client that dribbles: without the offset the scan is
// O(n^2) in the request size, and without the read count the repeated
// `buffered ++ chunk` is, and a 15 s timeout is a poor substitute for either.
fun read-request( s : socket, cfg : config, buffered : bytes,
                  deadline : int, first : bool,
                  scanned : int = 0, reads : int = 0 ) : <async|io> read-result
  match parse(buffered, cfg.limits, scanned)
    Parsed(req, rest) -> ReadOk(req, rest)
    Failed(e)         -> ReadFailed(e)
    Incomplete ->
      // An idle keep-alive connection gets the longer idle timeout; a
      // half-sent request gets the shorter request timeout.
      val budget = if first || buffered.is-notempty
                     then deadline - now-ms()
                     else cfg.idle-timeout-ms
      if budget <= 0 then
        ReadFailed(Parse-error(408, "request timed out"))
      elif reads >= cfg.max-reads then
        ReadFailed(Parse-error(408, "request arrived in too many pieces"))
      else match s.read-within(budget, cfg.read-chunk)
        Nothing -> ReadFailed(Parse-error(408, "request timed out"))
        Just(chunk) ->
          if chunk.is-empty then
            // peer closed: a clean close between requests is not an error
            if buffered.is-empty then ReadClosed
            else ReadFailed(Parse-error(400, "connection closed mid-request"))
          else
            val next = buffered ++ chunk
            if next.length > total-limit(cfg) then
              ReadFailed(Parse-error(413, "request is too large"))
            else
              // a terminator can straddle the join, so back up three octets
              read-request(s, cfg, next, deadline, first,
                           max(0, buffered.length - 3), reads + 1)

fun total-limit( cfg : config ) : int
  cfg.limits.max-request-line + cfg.limits.max-header-bytes + cfg.limits.max-body

fun send-response( s : socket, r : response, keep : bool ) : <async|io> ()
  // A write failure means the peer is gone; the connection is over either way.
  match try({ s.write(r.render(keep)) })
    Ok(_)     -> ()
    Error(ex) -> if is-cancellation(ex) then throw-exn(ex) else ()

// ----------------------------------------------------------------------------
// convenience
// ----------------------------------------------------------------------------

// Serve a route table.  The common case.
pub fun serve-routes( routes : list<route<<async,logger|io>>>,
                      ready : (server) -> <async|io> (),
                      cfg : config = default-config,
                      logs : log-config = default-log-config ) : io ()
  serve(fn(r) dispatch(routes, r), ready, cfg, logs)
