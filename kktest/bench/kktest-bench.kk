/* What this measures, and why.

   `kktest`'s cost is paid by every other package's test suite, so the numbers
   worth knowing are the ones that scale with a suite: how fast the generator
   produces values, and what a failing property costs once shrinking starts.

   Shrinking is measured separately from generation because it is the part that
   only runs when something is wrong, and it is the part with a bound (`check`
   walks at most 200 shrink steps) rather than a fixed cost.
*/
import kktest/bench
import kktest/random
import kktest/prop
import kktest/assert

// The raw generator: splitmix64 plus a reduction into a range.
fun rng-loop( r : rng, n : int, acc : int ) : io int
  if n <= 0 then acc
  else
    val (r1, v) = r.next-below(1000)
    rng-loop(r1, n - 1, acc + v)

// A property that always holds: this is generation and shrink-free checking.
fun passing( runs : int ) : io int
  check(gen-list(gen-int(0, 1000)), fn(xs) xs.length >= 0, runs = runs)
  runs

// A property that fails on the first non-trivial value, so every run pays for
// generation *and* for the shrink walk.  `check` reports a failure by throwing,
// which is what the caught exception here is.
fun failing( runs : int ) : io int
  match try({ check(gen-list(gen-int(0, 1000)), fn(xs) xs.is-nil, runs = runs) })
    Error(_) -> 1
    Ok(_)    -> 0

fun failing-loop( reps : int ) : io int
  fun go( i : int, seen : int ) : io int
    if i >= reps then seen else go(i + 1, seen + failing(100))
  go(0, 0)

fun main()
  report("kktest", [
    measure("splitmix64 next-below",              2000000, fn() rng-loop(rng(1), 2000000, 0)),
    measure("splitmix64 next-below",              8000000, fn() rng-loop(rng(1), 8000000, 0)),
    measure("check: n passing runs of a list<int>",   2000, fn() passing(2000)),
    measure("check: n passing runs of a list<int>",   8000, fn() passing(8000)),
    measure("check: n failures found and shrunk",     2000, fn() failing-loop(2000)),
    measure("check: n failures found and shrunk",     8000, fn() failing-loop(8000)),
  ])
