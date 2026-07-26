/* What this measures, and why.

   The map is a weight-balanced tree keyed on the hash, so `insert`, `lookup`
   and `remove` are documented as O(log n) plus the cost of one bucket.  A
   single size cannot show that, so each is reported at 1k, 4k and 16k entries
   with the *same total number of operations* at every size -- the workload is
   repeated as many times as needed.  That makes `units/s` directly comparable
   down the column: a 16x jump in `n` costing about 2x per operation is what
   O(log n) looks like, and a flat column would mean the tree was not being
   walked at all.

   The set rows are here because `union` and `intersect` are O(m log n) rather
   than the O(m + n) a sorted representation would give, and that is worth
   seeing next to the map numbers rather than inferred from them.
*/
import kktest/bench
import hashmap/map
import hashmap/set

// Keys are consecutive integers spread by a multiplicative hash, so the tree
// is not degenerate.  The map is correct either way -- a bad hash only makes a
// bucket longer -- but a benchmark of one long bucket would be measuring a
// linked list rather than the tree.
//
// This is the `?hash` the map resolves implicitly, which is why it is named
// `int/hash` rather than something descriptive.
pub fun int/hash( i : int ) : int
  (i * 2654435761) % 1000003

fun key( i : int ) : int
  i

fun build-map( n : int ) : io hmap<int,int>
  fun go( m : hmap<int,int>, i : int ) : io hmap<int,int>
    if i >= n then m else go(m.map/insert(key(i), i), i + 1)
  go(map/empty(), 0)

// Run `body` `reps` times, summing what it produced.
fun repeat-io( reps : int, body : () -> io int ) : io int
  fun go( i : int, seen : int ) : io int
    if i >= reps then seen else go(i + 1, seen + body())
  go(0, 0)

fun lookup-all( m : hmap<int,int>, n : int ) : io int
  fun go( i : int, seen : int ) : io int
    if i >= n then seen
    else
      val hit = match m.map/lookup(key(i))
                  Just(v) -> v
                  Nothing -> 0
      go(i + 1, seen + hit)
  go(0, 0)

// The running size is summed rather than returned at the end: removing every
// key leaves an empty map whatever the input was, and a result that does not
// depend on the work is a result the optimizer may produce without doing it.
fun remove-all( m : hmap<int,int>, n : int ) : io int
  fun go( acc : hmap<int,int>, i : int, seen : int ) : io int
    if i >= n then seen
    else
      val next = acc.map/remove(key(i))
      go(next, i + 1, seen + next.map/size)
  go(m, 0, 0)

fun set-of( lo : int, n : int ) : io hset<int>
  hset(list(lo, lo + n - 1).map(key))

// 512k operations per row, however they are split up.
val total : int = 512 * 1024

fun main()
  val m1  = build-map(1000)
  val m4  = build-map(4000)
  val m16 = build-map(16000)
  val sa  = set-of(0, 8000)
  val sb  = set-of(4000, 8000)
  report("hashmap", [
    measure("insert (map of 1k), n = inserts",   total, fn() repeat-io(total / 1000, fn() build-map(1000).map/size)),
    measure("insert (map of 4k), n = inserts",   total, fn() repeat-io(total / 4000, fn() build-map(4000).map/size)),
    measure("insert (map of 16k), n = inserts",  total, fn() repeat-io(total / 16000, fn() build-map(16000).map/size)),
    measure("lookup (map of 1k), n = lookups",   total, fn() repeat-io(total / 1000, fn() lookup-all(m1, 1000))),
    measure("lookup (map of 4k), n = lookups",   total, fn() repeat-io(total / 4000, fn() lookup-all(m4, 4000))),
    measure("lookup (map of 16k), n = lookups",  total, fn() repeat-io(total / 16000, fn() lookup-all(m16, 16000))),
    measure("remove (map of 1k), n = removals",  total, fn() repeat-io(total / 1000, fn() remove-all(m1, 1000))),
    measure("remove (map of 16k), n = removals", total, fn() repeat-io(total / 16000, fn() remove-all(m16, 16000))),
    measure("set union, 8k into 8k, n = inserts", 8000 * 32, fn() repeat-io(32, fn() sa.union(sb).set/size)),
    measure("set intersect, 8k and 8k",           8000 * 32, fn() repeat-io(32, fn() sa.intersect(sb).set/size)),
  ])
