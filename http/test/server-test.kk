import kktest/assert
import kktest/runner
import bytes/bytes
import runtime/task
import runtime/net
import logging/log
import http/message
import http/server

val quiet-logs : log-config
  = default-log-config(emit = fn(_line) ())

val test-config : config
  = default-config(port = 0, request-timeout-ms = 2000,
                   idle-timeout-ms = 2000, max-connections = 8,
                   max-requests = 8, max-reads = 64, read-chunk = 1024)

fun read-to-close( s : socket, acc : bytes = bytes-empty,
                   chunks : int = 20 ) : <async|io> bytes
  if chunks <= 0 then acc
  else match s.read-within(2000, 4096)
    Nothing -> acc
    Just(part) ->
      if part.is-empty then acc
      else read-to-close(s, acc ++ part, chunks - 1)

fun exchange( serve-request : (request) -> <async,logger|io> response,
              wire : string, cfg : config = test-config ) : io string
  val received = ref("")
  serve(serve-request, fn(srv)
    with-connection("127.0.0.1", srv.port) fn(sock)
      sock.write-string(wire)
      received := read-to-close(sock).to-string-lossy
  , cfg, quiet-logs)
  !received

fun ok-handler( r : request ) : <async,logger|io> response
  text-response(200, r.method ++ " " ++ r.path)

fun failing-handler( _r : request ) : <async,logger|io> response
  throw("handler exploded")

fun counted-handler( calls : ref<global,int>,
                     r : request ) : <async,logger|io> response
  calls := !calls + 1
  text-response(200, r.path)

fun occurrences( text : string, needle : string ) : int
  text.split(needle).length - 1

fun fragmented-request() : io string
  val received = ref("")
  serve(ok-handler, fn(srv)
    with-connection("127.0.0.1", srv.port) fn(sock)
      sock.write-string("GET /frag HTTP/1.1\r\nhost: test\r\n")
      // Give the connection task a chance to observe an incomplete head.
      yield()
      sock.write-string("connection: close\r\n\r\n")
      received := read-to-close(sock).to-string-lossy
  , test-config, quiet-logs)
  !received

fun main()
  run-tests([
    group("configuration", [
      test("the default configuration is valid", fn()
        assert-true(default-config.validate-config.is-nothing)
      ),
      test("loop-breaking values are rejected before binding", fn()
        assert-equal(default-config(max-connections = 0).validate-config,
                     Just("max-connections must be positive"))
        assert-equal(default-config(max-reads = 0).validate-config,
                     Just("max-reads must be positive"))
        assert-equal(default-config(read-chunk = 0).validate-config,
                     Just("read-chunk must be positive"))
        assert-equal(default-config(port = 65536).validate-config,
                     Just("port must be between 0 and 65535"))
      ),
      test("serve fails fast for invalid configuration", fn()
        assert-throws({
          serve(ok-handler, fn(_srv) (), default-config(max-connections = 0),
                quiet-logs)
        }, containing = "max-connections")
      ),
    ]),

    group("serving", [
      test("binds an ephemeral port and serves a request", fn()
        val out = exchange(ok-handler,
          "GET /hello HTTP/1.1\r\nhost: test\r\nconnection: close\r\n\r\n")
        assert-true(out.starts-with("HTTP/1.1 200 OK\r\n").bool, out)
        assert-true(out.ends-with("\r\n\r\nGET /hello").bool, out)
      , timeout-s = 30),
      test("assembles a request split across socket reads", fn()
        val out = fragmented-request()
        assert-true(out.starts-with("HTTP/1.1 200 OK\r\n").bool, out)
        assert-true(out.ends-with("\r\n\r\nGET /frag").bool, out)
      , timeout-s = 30),
      test("serves pipelined requests in order", fn()
        val calls = ref(0)
        val serve-request = fn(r) counted-handler(calls, r)
        val out = exchange(serve-request,
          "GET /one HTTP/1.1\r\nhost: test\r\n\r\n" ++
          "GET /two HTTP/1.1\r\nhost: test\r\nconnection: close\r\n\r\n")
        assert-equal(!calls, 2)
        assert-equal(occurrences(out, "HTTP/1.1 200 OK"), 2, out)
        assert-true(out.contains("\r\n\r\n/oneHTTP/1.1 200 OK"), out)
        assert-true(out.ends-with("\r\n\r\n/two").bool, out)
      , timeout-s = 30),
      test("a malformed request receives 400 without reaching the handler", fn()
        val calls = ref(0)
        val out = exchange(fn(r) counted-handler(calls, r),
          "GET relative HTTP/1.1\r\nhost: test\r\n\r\n")
        assert-equal(!calls, 0)
        assert-true(out.starts-with("HTTP/1.1 400 Bad Request\r\n").bool, out)
      , timeout-s = 30),
      test("a handler exception is contained as a 500", fn()
        val out = exchange(failing-handler,
          "GET /boom HTTP/1.1\r\nhost: test\r\nconnection: close\r\n\r\n")
        assert-true(out.starts-with("HTTP/1.1 500 Internal Server Error\r\n").bool, out)
        assert-true(out.contains("{\"error\":\"internal server error\"}"), out)
      , timeout-s = 30),
      test("max-requests closes a pipelined connection at the limit", fn()
        val calls = ref(0)
        val cfg = test-config(max-requests = 1)
        val out = exchange(fn(r) counted-handler(calls, r),
          "GET /one HTTP/1.1\r\nhost: test\r\n\r\n" ++
          "GET /two HTTP/1.1\r\nhost: test\r\n\r\n", cfg)
        assert-equal(!calls, 1)
        assert-equal(occurrences(out, "HTTP/1.1 200 OK"), 1, out)
        assert-true(out.contains("connection: close"), out)
      , timeout-s = 30),
    ]),
  ])
