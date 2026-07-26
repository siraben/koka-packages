/* What this measures, and why.

   Parsing is what a service does to every request body, so it is measured in
   throughput -- MiB of document per second -- at two document sizes, and
   separately for the two shapes with different costs: an array of small
   objects (allocation dominated) and one large flat object (dominated by the
   duplicate-key set, which is what makes object parsing O(n) instead of
   O(n^2)).

   Generation is measured on the same values, because a service that parses a
   request also writes a response, and the builder path is the reason that is
   not quadratic.

   The parser's default `max-bytes` is 1 MiB, so the large-document rows raise
   it explicitly.  Doing that here rather than silently in the library is the
   point of the limit being a parameter.
*/
import kktest/bench
import bytes/bytes
import json/value
import json/parse
import strbuilder/strbuilder

val big-limits : limits = default-limits(max-bytes = 64 * 1024 * 1024,
                                         max-members = 1000000)

// An array of `n` small objects: {"id":i,"name":"item-i","ok":true}
fun records( n : int ) : div json
  val items = list(0, n - 1).map fn(i)
    JsObject([ ("id", JsInt(i))
             , ("name", JsString("item-" ++ i.show))
             , ("ok", JsBool(i % 2 == 0)) ])
  JsArray(items)

// One flat object with `n` distinct keys: the shape that used to be O(n^2).
fun flat-object( n : int ) : div json
  JsObject(list(0, n - 1).map(fn(i) ("key-" ++ i.show, JsInt(i))))

fun parse-loop( doc : bytes, reps : int ) : io int
  fun go( i : int, seen : int ) : io int
    if i >= reps then seen
    else
      val got = match parse(doc, big-limits)
                  Right(_) -> doc.length
                  Left(e)  -> throw("benchmark document did not parse: " ++ e.show)
      go(i + 1, seen + got)
  go(0, 0)

fun show-loop( v : json, reps : int ) : io int
  fun go( i : int, seen : int ) : io int
    if i >= reps then seen else go(i + 1, seen + v.show.count)
  go(0, 0)

// Bytes per second is the useful rate here, so `n` is the number of KiB the
// row moved rather than the number of documents.
fun kib( total-bytes : int ) : int
  total-bytes / 1024

fun main()
  val small-v = records(200)                 // ~10 KiB
  val large-v = records(20000)               // ~1 MiB
  val flat-v  = flat-object(20000)
  val small-d = bytes(small-v.show)
  val large-d = bytes(large-v.show)
  val flat-d  = bytes(flat-v.show)
  report("json", [
    measure("parse, array of 200 objects (n = KiB)",
            kib(small-d.length * 2000), fn() kib(parse-loop(small-d, 2000))),
    measure("parse, array of 20k objects (n = KiB)",
            kib(large-d.length * 20), fn() kib(parse-loop(large-d, 20))),
    measure("parse, flat object, 20k keys (n = KiB)",
            kib(flat-d.length * 20), fn() kib(parse-loop(flat-d, 20))),
    measure("generate, array of 200 objects (n = KiB)",
            kib(small-d.length * 2000), fn() kib(show-loop(small-v, 2000))),
    measure("generate, array of 20k objects (n = KiB)",
            kib(large-d.length * 20), fn() kib(show-loop(large-v, 20))),
    measure("generate, flat object, 20k keys (n = KiB)",
            kib(flat-d.length * 20), fn() kib(show-loop(flat-v, 20))),
  ])
