/* What this measures, and why.

   `resource/scope` claims correctness, not speed, so the number that matters is
   the *overhead*: what it costs to route a resource through `with-resource`
   instead of acquiring and releasing it by hand.  Every native resource in this
   program goes through here, so a per-acquisition cost of a microsecond would
   show up in every request.

   The comparison rows are therefore a bare acquire/release pair with no
   handler at all, `with-resource` (one `finally`), `with-owned` (a `finally`
   plus a `ref` for the released flag), and `with-scope` holding `n` resources
   at once (a list of closures released in reverse).

   Nesting is measured separately at two depths because `finally` handlers
   compose, and a scope inside a scope inside a scope is what a request handler
   actually does.
*/
import kktest/bench
import resource/scope

// The baseline: acquire and release with no scoping mechanism at all, so the
// other rows can be read as overhead rather than as absolute cost.
fun by-hand( n : int ) : io int
  val counter = ref(0)
  fun go( i : int ) : io ()
    if i >= n then ()
    else
      counter := !counter + 1
      counter := !counter - 1
      go(i + 1)
  go(0)
  !counter + n

fun with-resource-n( n : int ) : io int
  val counter = ref(0)
  fun go( i : int ) : io ()
    if i >= n then ()
    else
      with-resource({ counter := !counter + 1 }, fn(_) counter := !counter - 1, fn(_) ())
      go(i + 1)
  go(0)
  !counter + n

fun with-owned-n( n : int ) : io int
  val counter = ref(0)
  fun go( i : int ) : io ()
    if i >= n then ()
    else
      with-owned({ counter := !counter + 1 }, fn(_) counter := !counter - 1, fn(_h) ())
      go(i + 1)
  go(0)
  !counter + n

// Run `body` `reps` times, summing what it produced.
fun repeat-io( reps : int, body : () -> io int ) : io int
  fun go( i : int, seen : int ) : io int
    if i >= reps then seen else go(i + 1, seen + body())
  go(0, 0)

// One scope holding `n` resources, released in reverse on exit.
//
// `n` is kept well under 45000 here, which is where this segfaults on an 8 MiB
// stack: `release-all` nests each release inside the next with `finally`, so
// the pending releases are stack frames.  See the package README.
fun scope-of( n : int ) : io int
  val counter = ref(0)
  with-scope fn(s)
    fun go( i : int ) : io ()
      if i >= n then ()
      else
        s.acquire({ counter := !counter + 1 }, fn(_) counter := !counter - 1)
        go(i + 1)
    go(0)
  !counter + n

// `depth` scopes nested inside each other, entered and left `n / depth` times.
fun nested( n : int, depth : int ) : io int
  val counter = ref(0)
  fun down( d : int ) : io ()
    if d <= 0 then ()
    else with-resource({ counter := !counter + 1 }, fn(_) counter := !counter - 1,
                       fn(_) down(d - 1))
  fun go( i : int ) : io ()
    if i * depth >= n then () else { down(depth); go(i + 1) }
  go(0)
  !counter + n

fun main()
  report("resource", [
    measure("acquire/release by hand (no scope)", 2000000, fn() by-hand(2000000)),
    measure("with-resource",                     2000000, fn() with-resource-n(2000000)),
    measure("with-owned",                        2000000, fn() with-owned-n(2000000)),
    measure("with-scope of 1k, n = acquisitions", 2000000, fn() repeat-io(2000, fn() scope-of(1000))),
    measure("with-scope of 10k, n = acquisitions",2000000, fn() repeat-io(200, fn() scope-of(10000))),
    measure("with-resource nested 8 deep",       2000000, fn() nested(2000000, 8)),
    measure("with-resource nested 32 deep",      2000000, fn() nested(2000000, 32)),
  ])
