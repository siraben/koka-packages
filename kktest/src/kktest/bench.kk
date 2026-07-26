/* Timing and reporting for the packages' benchmarks.

   A benchmark in this tree answers one question: does an operation cost what
   its package's README says it costs?  So a measurement is always taken at two
   or more input sizes and printed next to a derived rate, and the tables are
   plain text a README can quote without reformatting.

   The clock is `kktest/sys`'s `mono-ms`, the same one the packages' timing
   tests use.  It has millisecond resolution, so a benchmark sizes its workload
   to run for tens of milliseconds at least; a run that lands on 0 ms is
   reported without a rate rather than with a rate divided out of noise.

   Each measurement is the *fastest* of `trials` runs.  The minimum is the
   honest summary: interference from the scheduler and from other processes can
   only add time to a run, never remove it.

   ## Why an action returns an `:int`

   A benchmark whose result is thrown away is a benchmark the optimizer is
   entitled to delete, and a deleted benchmark reports a very good number.  So
   `measure` takes an action that returns something derived from the work, and
   `report` prints the total.  The number itself is uninteresting; the point is
   that it is observed, so the work cannot be dropped on the way to it.
*/
module kktest/bench

import kktest/sys

// One measured row: what ran, how many units of work it did, how long the
// fastest run took, and a value derived from the work.
pub struct measurement
  label : string
  // Units of work -- the `n` the complexity claim is about.
  size  : int
  ms    : int
  check : int

// Run `action` `trials` times and keep the fastest run.
pub fun measure( label : string, size : int, action : () -> io int,
                 trials : int = 3 ) : io measurement
  val (ms, check) = fastest(action, trials, 0, Nothing, 0)
  Measurement(label, size, ms, check)

fun fastest( action : () -> io int, trials : int, done : int,
             best : maybe<int>, check : int ) : io (int, int)
  if done >= trials then
    match best
      Just(ms) -> (ms, check)
      Nothing  -> (0, check)     // `trials` was not positive: nothing was run
  else
    val t0 = mono-ms()
    val c  = action()
    val dt = mono-ms() - t0
    val next = match best
                 Nothing   -> Just(dt)
                 Just(old) -> Just(min(old, dt))
    fastest(action, trials, done + 1, next, check + c)

// Units of work per second, or "-" when the run was too short to divide by.
pub fun rate( m : measurement ) : string
  if m.ms <= 0 then "-" else ((m.size * 1000) / m.ms).show

// Print one table.  Column widths are fixed so that two runs line up under
// `diff`, and the body is Markdown so a README can quote it as it stands.
pub fun report( title : string, rows : list<measurement> ) : io ()
  println("")
  println("### " ++ title)
  println("")
  println(row("what", "n", "ms", "units/s"))
  println(row("-".repeat(42), "-".repeat(10), "-".repeat(7), "-".repeat(12)))
  rows.foreach fn(m)
    println(row(m.label, m.size.show, m.ms.show, m.rate))
  println("")
  println("checksum " ++ rows.map(check).sum.show ++
          "  (printed so the measured work cannot be optimized away)")

fun row( what : string, n : string, ms : string, r : string ) : string
  "| " ++ what.pad-right(42) ++ " | " ++ n.pad-left(10) ++ " | " ++
  ms.pad-left(7) ++ " | " ++ r.pad-left(12) ++ " |"
