/* What this measures, and why.

   A server logs one record per request, so the cost of a record sits directly
   on the request path.  Two things are worth separating: rendering a record to
   a JSON line, and going through the effect handler to get there.

   Both are reported at two field counts, because the field list is the part a
   caller controls: it is the difference between a log line that is free and
   one that is not.

   The `with-no-logger` row is the floor -- the handler runs but the record is
   discarded -- so the difference between it and the JSON rows is what
   rendering and emitting actually cost, rather than what the effect
   dispatch costs.
*/
import kktest/bench
import logging/log

val no-fields : list<field> = []

val eight-fields : list<field> =
  [ ("request-id", "r12345"), ("method", "GET"), ("path", "/items/42")
  , int/field("status", 200), int/field("duration-ms", 3)
  , ("peer", "127.0.0.1:51234"), ("service", "notes"), bool/field("cached", True) ]

// Rendering alone: no handler, no emit.
fun render-loop( n : int, fields : list<field> ) : io int
  fun go( i : int, seen : int ) : io int
    if i >= n then seen else go(i + 1, seen + render(Info, "request", fields, 1700000000000).count)
  go(0, 0)

// Through the effect handler and out to a sink that counts octets, which is
// the shape of a real emit without a syscall in the middle.
fun logger-loop( n : int, fields : list<field> ) : io int
  val counted = ref(0)
  with-json-logger(fn(line) counted := !counted + line.count, fn()
    fun go( i : int ) : <logger,io> ()
      if i >= n then () else { info("request", fields); go(i + 1) }
    go(0)
  )
  !counted

// The same loop with everything discarded: the cost of the effect alone.
fun no-logger-loop( n : int, fields : list<field> ) : io int
  val counted = ref(0)
  with-no-logger(fn()
    fun go( i : int ) : <logger,io> ()
      if i >= n then () else { info("request", fields); counted := !counted + 1; go(i + 1) }
    go(0)
  )
  !counted

fun main()
  report("logging", [
    measure("render, 0 fields",              500000, fn() render-loop(500000, no-fields)),
    measure("render, 8 fields",              500000, fn() render-loop(500000, eight-fields)),
    measure("info through json handler, 0 fields", 500000, fn() logger-loop(500000, no-fields)),
    measure("info through json handler, 8 fields", 500000, fn() logger-loop(500000, eight-fields)),
    measure("info through no-op handler, 8 fields", 500000, fn() no-logger-loop(500000, eight-fields)),
  ])
