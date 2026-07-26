/* What this measures, and why.

   The package exists for one reason: `s := s ++ x` in a loop is O(n^2) and the
   builder is O(n).  So the first two pairs of rows are exactly that comparison,
   at `n` and `4n`, on the same input.  The pair is the measurement; either row
   on its own says nothing, because an absolute time is satisfied by both
   complexities at a small enough `n`.

   JSON escaping is measured separately because it walks the string character
   by character, which is a different cost from appending it.
*/
import kktest/bench
import strbuilder/strbuilder

// The O(n) path: one growable buffer.
fun with-builder( n : int, chunk : string ) : io int
  fun go( b : strbuilder, i : int ) : io strbuilder
    if i <= 0 then b else go(b.append(chunk), i - 1)
  go(strbuilder(), n).finish.count

// The O(n^2) path the package exists to replace: every step copies everything
// built so far.
fun with-concat( n : int, chunk : string ) : io int
  fun go( acc : string, i : int ) : io string
    if i <= 0 then acc else go(acc ++ chunk, i - 1)
  go("", n).count

fun escape-loop( n : int, s : string ) : io int
  fun go( i : int, seen : int ) : io int
    if i >= n then seen
    else go(i + 1, seen + build(fn(b) b.append-json-string(s)).count)
  go(0, 0)

fun main()
  val chunk = "0123456789"
  // half of it needs escaping, so neither the escape path nor the copy path
  // dominates by accident
  val nasty = "a\"b\\c\nd\te\r" ++ "plain text plain text plain text"
  report("strbuilder", [
    measure("builder append of a 10-char chunk", 2000000, fn() with-builder(2000000, chunk)),
    measure("builder append of a 10-char chunk", 8000000, fn() with-builder(8000000, chunk)),
    measure("naive ++ of a 10-char chunk",         20000, fn() with-concat(20000, chunk)),
    measure("naive ++ of a 10-char chunk",         80000, fn() with-concat(80000, chunk)),
    measure("append-json-string, 41-char value",   50000, fn() escape-loop(50000, nasty)),
    measure("append-json-string, 41-char value",  200000, fn() escape-loop(200000, nasty)),
  ])
