/* TCP and DNS, as cancellable async operations.

   Every operation here suspends the calling task rather than blocking the
   process, and every one is cancellable: the task is parked on the request,
   and cancelling the group wakes it with `Cancelled`, which raises and unwinds
   through the socket's `finally`.

   Sockets are integrated with `resource/scope`: `with-listener`, `with-socket`
   and `with-connection` close on success, on failure and on cancellation.  A
   socket closed while a read is outstanding completes that read as cancelled,
   so no task is left waiting on a closed socket -- that is handled in the C
   shim, not by hoping.

   Raw handles never leave `runtime/loop`; a `:socket` is an integer id.
*/
module runtime/net

import bytes/bytes
import runtime/loop
import runtime/task

// A connected stream.
pub value struct socket( id : int )

// A listening socket.
pub value struct listener( id : int )

// ----------------------------------------------------------------------------
// listening and accepting
// ----------------------------------------------------------------------------

// Bind and listen.  Passing port 0 asks the operating system for a free port;
// `port` reports which one was chosen.
pub fun net/listen( host : string = "127.0.0.1", port : int = 0, backlog : int = 128 ) : io listener
  loop-init()
  Listener(loop/listen(host, port, backlog))

pub fun port( l : listener ) : io int
  bound-port(l.id)

pub fun listener/close( l : listener ) : io ()
  close-stream(l.id)

// Run `action` with a listener, closing it on every exit path.
pub fun with-listener( action : (listener) -> io a,
                       host : string = "127.0.0.1", port : int = 0,
                       backlog : int = 128 ) : io a
  val l = net/listen(host, port, backlog)
  finally({ close(l) }, { action(l) })

// Wait for a connection.  Cancellable.
pub fun accept( l : listener ) : <async|io> socket
  val req = fresh-request()
  val rc  = arm-accept(l.id, req)
  if rc != 0 then throw("cannot accept: " ++ strerror(rc))
  val c = await(req)
  if !c.is-ok then throw("accept failed: " ++ c.error-message)
  Socket(c.value)

// Wait for a connection with a deadline.  `Nothing` means the deadline passed.
pub fun accept-within( l : listener, ms : int ) : <async|io> maybe<socket>
  val req = fresh-request()
  val rc  = arm-accept(l.id, req)
  if rc != 0 then throw("cannot accept: " ++ strerror(rc))
  match await-within(req, ms)
    Nothing ->
      // the deadline won the race: the accept is still armed, so clear it or
      // the next arm on this listener fails with EBUSY
      cancel-accept(l.id)
      Nothing
    Just(c) ->
      if !c.is-ok then throw("accept failed: " ++ c.error-message)
      Just(Socket(c.value))

// ----------------------------------------------------------------------------
// connecting
// ----------------------------------------------------------------------------

pub fun net/connect( host : string, port : int ) : <async|io> socket
  loop-init()
  val req = fresh-request()
  val id  = loop/connect(host, port, req)
  val c   = await(req)
  if !c.is-ok then
    close-stream(id)
    throw("cannot connect to " ++ host ++ ":" ++ port.show ++ ": " ++ c.error-message)
  Socket(id)

pub fun with-connection( host : string, port : int,
                         action : (socket) -> <async,io|e> a ) : <async,io|e> a
  with-async-resource({ net/connect(host, port) }, socket/close, action)

// ----------------------------------------------------------------------------
// reading and writing
// ----------------------------------------------------------------------------

// Read at most `max` octets.  An empty result means the peer closed the
// stream.  Bounded by construction: there is no unbounded read.
pub fun read( s : socket, max : int = 65536 ) : <async|io> bytes
  val req = fresh-request()
  val rc  = arm-read(s.id, req, max)
  if rc != 0 then throw("cannot read: " ++ strerror(rc))
  val c = await(req)
  if !c.is-ok then throw("read failed: " ++ c.error-message)
  c.data

// Read with a deadline.  `Nothing` means the deadline passed; an empty result
// means end of stream.
pub fun read-within( s : socket, ms : int, max : int = 65536 ) : <async|io> maybe<bytes>
  val req = fresh-request()
  val rc  = arm-read(s.id, req, max)
  if rc != 0 then throw("cannot read: " ++ strerror(rc))
  match await-within(req, ms)
    Nothing ->
      cancel-read(s.id)
      Nothing
    Just(c) ->
      if !c.is-ok then throw("read failed: " ++ c.error-message)
      Just(c.data)

// Write everything.  libuv queues the whole buffer, so a partial write is not
// something the caller has to handle.
pub fun write( s : socket, data : bytes ) : <async|io> ()
  if data.is-empty then ()
  else
    val req = fresh-request()
    val rc  = arm-write(s.id, req, data)
    if rc != 0 then throw("cannot write: " ++ strerror(rc))
    val c = await(req)
    if !c.is-ok then throw("write failed: " ++ c.error-message)

pub fun write-string( s : socket, text : string ) : <async|io> ()
  s.write(bytes(text))

// ----------------------------------------------------------------------------
// closing
// ----------------------------------------------------------------------------

// Close the socket.  Idempotent.  Any task waiting on a read of this socket is
// woken with a cancelled status rather than left parked forever.
pub fun socket/close( s : socket ) : io ()
  close-stream(s.id)

pub fun socket/is-open( s : socket ) : io bool
  loop/is-open(s.id)

pub fun peer( s : socket ) : io string
  peer-address(s.id)

// Run `action` with a socket, closing it when the current task ends -- on
// success, on failure, and on cancellation.  See `with-async-resource` for why
// this defers to task exit rather than using `finally`.
pub fun with-socket( s : socket, action : (socket) -> <async,io|e> a ) : <async,io|e> a
  with-async-resource({ s }, socket/close, action)

// ----------------------------------------------------------------------------
// dns
// ----------------------------------------------------------------------------

// Resolve a host name to one IPv4 address.  Cancellable.
pub fun resolve( host : string ) : <async|io> string
  loop-init()
  val req = fresh-request()
  val rc  = arm-resolve(host, req)
  if rc != 0 then throw("cannot resolve " ++ host ++ ": " ++ strerror(rc))
  val c = await(req)
  if !c.is-ok then throw("cannot resolve " ++ host ++ ": " ++ c.error-message)
  c.text
