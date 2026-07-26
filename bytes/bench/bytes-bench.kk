/* What this measures, and why.

   `bytes`'s header makes three cost claims a caller can be bitten by: the
   builder appends in amortized O(1), so building is O(n); `cat` copies both
   operands, so building by repeated `++` is O(n^2); and `slice` copies rather
   than aliasing, so it is O(len) and not O(1).

   Each is measured at `n` and `4n`, because that is the shape of the claim:
   O(n) predicts about 4x, O(n^2) about 16x.  An absolute threshold would be
   satisfied by either.
*/
import kktest/bench
import bytes/bytes

// Build `n` chunks through the builder: the O(n) path.
fun build-with-builder( n : int, chunk : bytes ) : io int
  fun go( b : builder, i : int ) : io builder
    if i <= 0 then b else go(b.snoc(chunk), i - 1)
  go(builder-empty(), n).finish.length

// Build the same thing by repeated `++`: O(n^2), one copy of everything so far
// per step.
fun build-with-cat( n : int, chunk : bytes ) : io int
  fun go( acc : bytes, i : int ) : io bytes
    if i <= 0 then acc else go(acc ++ chunk, i - 1)
  go(bytes-empty, n).length

// `slice` allocates and copies, so the cost is in `len`, not in the size of
// the sequence it comes out of.
fun slice-loop( b : bytes, n : int, len : int ) : io int
  fun go( i : int, seen : int ) : io int
    if i >= n then seen else go(i + 1, seen + b.slice(i % 1024, len).length)
  go(0, 0)

fun hash-loop( b : bytes, n : int ) : io int
  fun go( i : int, seen : int ) : io int
    if i >= n then seen else go(i + 1, seen + b.hash)
  go(0, 0)

// A needle that is not there, so the whole haystack is scanned every time.
fun index-loop( hay : bytes, needle : bytes, n : int ) : io int
  fun go( i : int, seen : int ) : io int
    if i >= n then seen
    else
      val found = match hay.index-of(needle)
                    Just(j) -> j
                    Nothing -> 1
      go(i + 1, seen + found)
  go(0, 0)

fun main()
  val chunk = bytes("0123456789")
  val big   = bytes/replicate(65, 1024 * 1024)          // 1 MiB of 'A'
  val absent = bytes("needle")
  report("bytes", [
    measure("builder snoc of a 10-octet chunk",  2000000, fn() build-with-builder(2000000, chunk)),
    measure("builder snoc of a 10-octet chunk",  8000000, fn() build-with-builder(8000000, chunk)),
    measure("repeated ++ of a 10-octet chunk",     20000, fn() build-with-cat(20000, chunk)),
    measure("repeated ++ of a 10-octet chunk",     80000, fn() build-with-cat(80000, chunk)),
    measure("slice 4 KiB out of a 1 MiB sequence", 200000, fn() slice-loop(big, 200000, 4096)),
    measure("slice 4 KiB out of a 1 MiB sequence", 800000, fn() slice-loop(big, 800000, 4096)),
    measure("hash 1 MiB, FNV-1a (n = MiB)",           64, fn() hash-loop(big, 64)),
    measure("hash 1 MiB, FNV-1a (n = MiB)",          256, fn() hash-loop(big, 256)),
    measure("index-of, no match, 1 MiB (n = MiB)",    32, fn() index-loop(big, absent, 32)),
    measure("index-of, no match, 1 MiB (n = MiB)",   128, fn() index-loop(big, absent, 128)),
  ])
