/* What this measures, and why.

   `http/message`'s parser is on the path of every request, and the header
   block is the part whose cost a client controls, so parsing is reported at
   two header counts.  Rendering is reported separately because a response goes
   out through the builder, which is the reason it is not quadratic in the
   header count.

   The dribbled row is the one worth having.  `parse` takes a `from` offset --
   a promise that no terminator begins before it -- and the server passes
   `buffered.length - 3` so a client sending a request one octet at a time
   costs O(total) scanning across all the calls rather than O(total^2).  The
   two dribbled rows re-scan from 0 and from the offset, at the same input, so
   the difference is exactly what that parameter buys.

   Routing is measured on a five-route table, the size the reference service
   uses; a linear scan over five patterns is what the router promises and not
   something that needs to scale.
*/
import kktest/bench
import bytes/bytes
import http/message
import http/router

fun request-with( headers : int ) : bytes
  val hs = list(1, headers).map(fn(i) "x-header-" ++ i.show ++ ": value-" ++ i.show ++ "\r\n").join
  bytes("GET /items/42?limit=10 HTTP/1.1\r\nhost: example.test\r\n" ++ hs ++ "\r\n")

fun parse-loop( buf : bytes, reps : int ) : io int
  fun go( i : int, seen : int ) : io int
    if i >= reps then seen
    else
      val got = match parse(buf)
                  Parsed(r, _) -> r.headers.length
                  Incomplete   -> throw("benchmark request was incomplete")
                  Failed(e)    -> throw("benchmark request failed to parse: " ++ e.message)
      go(i + 1, seen + got)
  go(0, 0)

// One request arriving `step` octets at a time.  `hint` decides whether each
// call rescans from the start or resumes just behind the last scan.
fun dribble( buf : bytes, step : int, hint : bool ) : io int
  fun go( have : int, scanned : int, calls : int ) : io int
    if have > buf.length then calls
    else
      val head-part = buf.take(have)
      match parse(head-part, default-limits, if hint then max(0, have - step - 3) else 0)
        Parsed(_, _) -> calls + 1
        Failed(e)    -> throw("dribbled request failed: " ++ e.message)
        Incomplete   -> go(have + step, have, calls + 1)
  go(step, 0, 0)

fun dribble-loop( buf : bytes, reps : int, hint : bool ) : io int
  fun go( i : int, seen : int ) : io int
    if i >= reps then seen else go(i + 1, seen + dribble(buf, 1, hint))
  go(0, 0)

fun render-loop( r : response, reps : int ) : io int
  fun go( i : int, seen : int ) : io int
    if i >= reps then seen else go(i + 1, seen + r.render(True).length)
  go(0, 0)

val routes : list<route<total>> =
  [ route("GET",    "/items",     fn(_r, _p) text-response(200, "list"))
  , route("POST",   "/items",     fn(_r, _p) text-response(201, "created"))
  , route("GET",    "/items/:id", fn(_r, _p) text-response(200, "one"))
  , route("PUT",    "/items/:id", fn(_r, _p) text-response(200, "updated"))
  , route("DELETE", "/items/:id", fn(_r, _p) text-response(204, "")) ]

fun route-loop( reps : int, path : string, verb : string ) : io int
  fun go( i : int, seen : int ) : io int
    if i >= reps then seen
    else
      val hit = match route-match(routes, verb, path)
                  Matched(_, ps)  -> 1 + ps.length
                  WrongMethod(allow) -> allow.length
                  NoSuchPath      -> 0
      go(i + 1, seen + hit)
  go(0, 0)

fun main()
  val small = request-with(2)
  val large = request-with(30)
  val body  = bytes("{\"id\":42,\"name\":\"an item\",\"ok\":true}")
  val resp  = response(200, body, [("content-type", "application/json"), ("x-trace", "abc123")])
  report("http", [
    measure("parse a request, 3 headers",       200000, fn() parse-loop(small, 200000)),
    measure("parse a request, 31 headers",      100000, fn() parse-loop(large, 100000)),
    measure("render a 200 with 2 headers",      200000, fn() render-loop(resp, 200000)),
    // n is the number of parse calls: one per octet fed, 200 requests over.
    measure("dribbled 1 octet/read, with `from`",  large.length * 200,
            fn() dribble-loop(large, 200, True)),
    measure("dribbled 1 octet/read, rescan from 0", large.length * 200,
            fn() dribble-loop(large, 200, False)),
    measure("route-match, 5 routes, last matches", 500000, fn() route-loop(500000, "/items/42", "DELETE")),
    measure("route-match, 5 routes, no match",     500000, fn() route-loop(500000, "/nope", "GET")),
  ])
