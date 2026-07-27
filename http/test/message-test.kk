import kktest/assert
import kktest/runner
import bytes/bytes
import http/message
import http/router

fun p( text : string, lim : limits = default-limits ) : div parse-result
  parse(bytes(text), lim)

fun parsed( text : string ) : div request
  match p(text)
    Parsed(r, _) -> r
    Failed(e)    -> Request("!failed:" ++ e.status.show, e.message, "", "", [], bytes-empty)
    Incomplete   -> Request("!incomplete", "", "", "", [], bytes-empty)

fun status-of( text : string, lim : limits = default-limits ) : div int
  match p(text, lim)
    Failed(e) -> e.status
    _         -> 0

fun get( path : string ) : string
  "GET " ++ path ++ " HTTP/1.1\r\nhost: x\r\n\r\n"

// A request assembled directly, bypassing `parse` -- the only way to reach the
// header values `parse` refuses.
fun built( headers : list<(string, string)> ) : request
  Request("POST", "/", "", "HTTP/1.1", headers, bytes-empty)

// Routes for the router tests; the handler just names what matched.
fun mark( name : string ) : ((request, params) -> total response)
  fn(_r, ps) text-response(200, name ++ ":" ++ ps.map(fn(kv) kv.snd).join(","))

val test-routes : list<route<total>>
  = [ route("GET",    "/health",    mark("health"))
    , route("GET",    "/items",     mark("list"))
    , route("POST",   "/items",     mark("create"))
    , route("GET",    "/items/:id", mark("show"))
    , route("DELETE", "/items/:id", mark("delete"))
    ]

fun allow-header( verb : string, path : string ) : string
  val r = Request(verb, path, "", "HTTP/1.1", [], bytes-empty)
  dispatch(test-routes, r).headers.filter(fn(h) h.fst == "allow").map(fn(h) h.snd).join("")

fun dispatched( verb : string, path : string ) : string
  val r = Request(verb, path, "", "HTTP/1.1", [], bytes-empty)
  val resp = dispatch(test-routes, r)
  resp.status.show ++ " " ++ resp.body.to-string-lossy

fun main()
  run-tests([
    group("request parsing", [
      test("a simple GET", fn()
        val r = parsed(get("/items"))
        assert-equal(r.method, "GET")
        assert-equal(r.path, "/items")
        assert-equal(r.version, "HTTP/1.1")
        assert-equal(r.header("host").default("-"), "x")
      ),
      test("header names are case insensitive", fn()
        val r = parsed("GET / HTTP/1.1\r\nContent-Type: text/plain\r\n\r\n")
        assert-equal(r.header("content-type").default("-"), "text/plain")
        assert-equal(r.header("CONTENT-TYPE").default("-"), "text/plain")
      ),
      test("a query string is separated from the path", fn()
        val r = parsed("GET /items?a=1&b=2 HTTP/1.1\r\n\r\n")
        assert-equal(r.path, "/items")
        assert-equal(r.query, "a=1&b=2")
      ),
      test("a body is read according to content-length", fn()
        val r = parsed("POST /items HTTP/1.1\r\ncontent-length: 5\r\n\r\nhello")
        assert-equal(r.body.to-string-lossy, "hello")
        assert-equal(r.content-length, Just(5))
      ),
      test("content-length tells absent from unparseable from zero", fn()
        // `parse` refuses the last two, so these are built by hand -- which is
        // exactly the caller `content-length` has to stay honest with.
        assert-equal(built([]).content-length, Nothing,
                     "an absent header must not read as a length")
        assert-equal(built([("content-length", "0")]).content-length, Just(0))
        assert-equal(built([("content-length", "abc")]).content-length, Nothing,
                     "an unparseable length must not read as 0")
        assert-equal(built([("content-length", "-1")]).content-length, Nothing)
      ),
      test("values containing colons survive", fn()
        val r = parsed("GET / HTTP/1.1\r\nhost: example.com:8080\r\n\r\n")
        assert-equal(r.header("host").default("-"), "example.com:8080")
      ),
      test("a partial request is incomplete, not an error", fn()
        match p("GET /items HTTP/1.1\r\nhost: x\r\n")
          Incomplete -> ()
          _ -> assert-fail("expected Incomplete")
        match p("POST / HTTP/1.1\r\ncontent-length: 10\r\n\r\nshort")
          Incomplete -> ()
          _ -> assert-fail("expected Incomplete for a truncated body")
      ),
      test("what follows a request is handed back", fn()
        match p(get("/a") ++ get("/b"))
          Parsed(r, rest) ->
            assert-equal(r.path, "/a")
            assert-true(rest.to-string-lossy.starts-with("GET /b").bool)
          _ -> assert-fail("expected a parsed request")
      ),
    ]),

    group("malformed requests", [
      test("a bad request line is 400", fn()
        assert-equal(status-of("GARBAGE\r\n\r\n"), 400)
        assert-equal(status-of("GET /x\r\n\r\n"), 400)
        assert-equal(status-of("GET /x SPDY/1\r\n\r\n"), 400)
        assert-equal(status-of("GET relative HTTP/1.1\r\n\r\n"), 400)
      ),
      test("a malformed header is 400", fn()
        assert-equal(status-of("GET / HTTP/1.1\r\nnovalue\r\n\r\n"), 400)
      ),
      test("a malformed content-length is 400", fn()
        assert-equal(status-of("POST / HTTP/1.1\r\ncontent-length: abc\r\n\r\n"), 400)
      ),
      test("chunked encoding is refused with 501, not half-handled", fn()
        assert-equal(status-of("POST / HTTP/1.1\r\ntransfer-encoding: chunked\r\n\r\n"), 501)
      ),

      // Everything below is a framing disagreement: a case where this server
      // and a front end in front of it could split the byte stream into a
      // different number of requests.  That is request smuggling, so each one
      // must be a rejection and never a guess.
      test("two conflicting content-lengths are refused", fn()
        assert-equal(status-of(
          "POST / HTTP/1.1\r\ncontent-length: 0\r\ncontent-length: 32\r\n\r\n"), 400)
      ),
      test("a repeated but identical content-length is accepted", fn()
        assert-equal(status-of(
          "POST / HTTP/1.1\r\ncontent-length: 1\r\ncontent-length: 1\r\n\r\nx"), 0)
      ),
      test("a comma list of differing lengths is refused", fn()
        assert-equal(status-of("POST / HTTP/1.1\r\ncontent-length: 0, 32\r\n\r\n"), 400)
      ),
      test("transfer-encoding together with content-length is refused", fn()
        assert-equal(status-of(
          "POST / HTTP/1.1\r\ntransfer-encoding: chunked\r\ncontent-length: 5\r\n\r\n"), 400)
      ),
      test("a non-decimal content-length is refused", fn()
        // `parse-int` accepts all three of these; HTTP does not
        assert-equal(status-of("POST / HTTP/1.1\r\ncontent-length: +13\r\n\r\n"), 400)
        assert-equal(status-of("POST / HTTP/1.1\r\ncontent-length: 0x0d\r\n\r\n"), 400)
        assert-equal(status-of("POST / HTTP/1.1\r\ncontent-length: 1_3\r\n\r\n"), 400)
        assert-equal(status-of("POST / HTTP/1.1\r\ncontent-length: -1\r\n\r\n"), 400)
      ),
      test("a bare LF in the head is refused", fn()
        assert-equal(status-of("POST / HTTP/1.1\r\nhost: x\ncontent-length: 3\r\n\r\n"), 400)
      ),
      test("obsolete line folding is refused", fn()
        assert-equal(status-of("GET / HTTP/1.1\r\nhost: x\r\n more\r\n\r\n"), 400)
      ),
      test("a header name that is not a token is refused", fn()
        assert-equal(status-of("GET / HTTP/1.1\r\nbad name: x\r\n\r\n"), 400)
        assert-equal(status-of("GET / HTTP/1.1\r\nhost : x\r\n\r\n"), 400)
      ),
    ]),

    group("limits", [
      test("an over-long request line is 414", fn()
        val long = "GET /" ++ "a".repeat(200) ++ " HTTP/1.1\r\n\r\n"
        assert-equal(status-of(long, default-limits(max-request-line = 50)), 414)
      ),
      test("too many headers is 431", fn()
        val many = "GET / HTTP/1.1\r\n" ++ "x: 1\r\n".repeat(20) ++ "\r\n"
        assert-equal(status-of(many, default-limits(max-headers = 5)), 431)
      ),
      test("an over-large body is 413", fn()
        val big = "POST / HTTP/1.1\r\ncontent-length: 5000\r\n\r\n"
        assert-equal(status-of(big, default-limits(max-body = 100)), 413)
      ),
      test("a header block that will never fit is refused before it completes", fn()
        val lim = default-limits(max-request-line = 10, max-header-bytes = 10)
        match p("GET / HTTP/1.1\r\n" ++ "x: 1\r\n".repeat(50), lim)
          Failed(e) -> assert-equal(e.status, 431)
          _ -> assert-fail("expected the oversized header block to be refused")
      ),
    ]),

    group("keep-alive", [
      test("HTTP/1.1 defaults to keep-alive", fn()
        assert-true(parsed(get("/")).wants-keep-alive)
      ),
      test("connection: close is honoured", fn()
        assert-false(parsed("GET / HTTP/1.1\r\nconnection: close\r\n\r\n").wants-keep-alive)
      ),
      test("HTTP/1.0 defaults to closing", fn()
        assert-false(parsed("GET / HTTP/1.0\r\n\r\n").wants-keep-alive)
      ),
    ]),

    group("responses", [
      test("status line, content-length and connection", fn()
        val out = response(200, bytes("hi")).render(True).to-string-lossy
        assert-true(out.starts-with("HTTP/1.1 200 OK\r\n").bool, out)
        assert-true(out.contains("content-length: 2"), out)
        assert-true(out.contains("connection: keep-alive"), out)
        assert-true(out.ends-with("\r\n\r\nhi").bool, out)
      ),
      test("close is reflected", fn()
        assert-true(response(204).render(False).to-string-lossy.contains("connection: close"))
      ),
      test("custom headers are emitted", fn()
        val out = json-response(201, "{}").render(True).to-string-lossy
        assert-true(out.contains("content-type: application/json"), out)
      ),
      // Each control character gets its own assertion: `assert-false(A && B)`
      // would pass when only one of the two held, which is exactly the case
      // where CR is handled and a bare LF still gets through.
      test("a header carrying CR or LF is dropped, not patched up", fn()
        val nul = string([char(0)])
        ["a\r\nevil: 1", "a\nevil: 1", "a\revil: 1", "a" ++ nul ++ "evil: 1"].foreach fn(payload)
          val out = response(200, bytes-empty, [("x", payload)]).render(True).to-string-lossy
          assert-false(out.contains("evil"), "injected via " ++ payload.show ++ ": " ++ out)
          assert-false(out.contains("x: "), "the header should be dropped whole: " ++ out)
      ),
      test("a header name that is not a token is dropped", fn()
        val out = response(200, bytes-empty, [("bad name", "1"), ("ok-name", "2")])
                    .render(True).to-string-lossy
        assert-false(out.contains("bad name"), out)
        assert-true(out.contains("ok-name: 2"), out)
      ),
      test("a handler cannot supply its own framing headers", fn()
        val out = response(200, bytes("A"),
                           [("content-length", "0"), ("connection", "close"),
                            ("transfer-encoding", "chunked")]).render(True).to-string-lossy
        assert-equal(out.split("content-length").length - 1, 1, out)
        assert-equal(out.split("connection").length - 1, 1, out)
        assert-true(out.contains("content-length: 1"), out)
        assert-true(out.contains("connection: keep-alive"), out)
        assert-false(out.contains("transfer-encoding"), out)
      ),
      test("a reason phrase cannot inject a header", fn()
        val out = response(200, bytes-empty, [], reason = "OK\r\nevil: 1")
                    .render(True).to-string-lossy
        assert-false(out.contains("evil"), out)
      ),
      test("default reasons", fn()
        assert-equal(default-reason(404), "Not Found")
        assert-equal(default-reason(405), "Method Not Allowed")
        assert-equal(default-reason(413), "Payload Too Large")
      ),
    ]),

    group("routing", [
      test("literal paths", fn()
        assert-equal(dispatched("GET", "/health"), "200 health:")
        assert-equal(dispatched("GET", "/items"), "200 list:")
        assert-equal(dispatched("POST", "/items"), "200 create:")
      ),
      test("path parameters", fn()
        assert-equal(dispatched("GET", "/items/42"), "200 show:42")
        assert-equal(dispatched("DELETE", "/items/abc"), "200 delete:abc")
      ),
      test("an unknown path is 404", fn()
        assert-true(dispatched("GET", "/nope").starts-with("404").bool)
        assert-true(dispatched("GET", "/items/1/extra").starts-with("404").bool)
      ),
      test("a known path with the wrong method is 405", fn()
        assert-true(dispatched("PUT", "/items").starts-with("405").bool)
        assert-true(dispatched("POST", "/items/1").starts-with("405").bool)
      ),
      test("405 lists the methods that would work", fn()
        val allow = allow-header("PUT", "/items")
        assert-true(allow.contains("GET"), allow)
        assert-true(allow.contains("POST"), allow)
      ),
      test("an empty parameter does not match", fn()
        assert-true(dispatched("GET", "/items/").starts-with("404").bool)
      ),
      test("methods are matched case insensitively", fn()
        assert-equal(dispatched("get", "/health"), "200 health:")
      ),
      test("pattern matching in isolation", fn()
        assert-true(match-pattern("/a/:x", "/a/1").is-just)
        assert-false(match-pattern("/a/:x", "/a").is-just)
        assert-false(match-pattern("/a", "/a/1").is-just)
        match match-pattern("/a/:x/b/:y", "/a/1/b/2")
          Just(ps) ->
            assert-equal(ps.param("x").default("-"), "1")
            assert-equal(ps.param("y").default("-"), "2")
          Nothing -> assert-fail("expected a match")
      ),
    ]),
  ])
