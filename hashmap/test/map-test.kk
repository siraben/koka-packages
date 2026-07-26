import kktest/assert
import kktest/runner
import kktest/prop
import hashmap/map

// ----------------------------------------------------------------------------
// Reference implementation: an association list.  Every property below is
// stated against this, so a bug in the tree shows up as a disagreement with
// something obviously correct rather than as a self-consistent wrong answer.
// ----------------------------------------------------------------------------

alias ref-map = list<(int, int)>

fun ref-insert( m : ref-map, k : int, v : int ) : ref-map
  m.filter(fn(kv) kv.fst != k) ++ [(k, v)]

fun ref-remove( m : ref-map, k : int ) : ref-map
  m.filter(fn(kv) kv.fst != k)

fun ref-lookup( m : ref-map, k : int ) : maybe<int>
  match m.filter(fn(kv) kv.fst == k)
    Cons(kv, _) -> Just(kv.snd)
    Nil         -> Nothing

// ----------------------------------------------------------------------------
// A key whose hash collides on purpose, so collision handling is exercised
// rather than assumed.
// ----------------------------------------------------------------------------

struct clashing
  tag : int

fun clashing/hash( c : clashing ) : int
  c.tag % 3        // three buckets for everything

fun clashing/(==)( a : clashing, b : clashing ) : bool
  a.tag == b.tag

fun clashing/show( c : clashing ) : string
  "C" ++ c.tag.show

fun int/hash( i : int ) : int
  i

fun mi( m : maybe<int> ) : string
  match m
    Just(x) -> "Just(" ++ x.show ++ ")"
    Nothing -> "Nothing"

// A sequence of operations applied to both implementations must agree.
fun ops-agree( ops : list<(int, int)> ) : div bool
  val built  = ops.foldl(map/empty(), fn(m, o) m.insert(o.fst, o.snd))
  val refbuilt = ops.foldl([], fn(m : ref-map, o) ref-insert(m, o.fst, o.snd))
  built.size == refbuilt.length &&
    refbuilt.all(fn(kv) built.lookup(kv.fst) == Just(kv.snd)) &&
    built.list.all(fn(kv) ref-lookup(refbuilt, kv.fst) == Just(kv.snd)) &&
    built.is-balanced && built.is-ordered

fun insert-then-lookup( xs : list<int> ) : div bool
  val m = xs.foldl(map/empty(), fn(acc, x) acc.insert(x, x * 2))
  xs.all(fn(x) m.lookup(x) == Just(x * 2))

fun remove-all-empties( xs : list<int> ) : div bool
  val m  = xs.foldl(map/empty(), fn(acc, x) acc.insert(x, x))
  val m2 = xs.foldl(m, fn(acc, x) acc.remove(x))
  m2.size == 0 && m2.is-balanced

fun stays-balanced( xs : list<int> ) : div bool
  val m = xs.foldl(map/empty(), fn(acc, x) acc.insert(x, x))
  m.is-balanced && m.is-ordered

fun main()
  run-tests([
    group("basics", [
      test("empty", fn()
        val m : hmap<int,int> = map/empty()
        assert-equal(m.size, 0)
        assert-true(m.is-empty)
        assert-equal(mi(m.lookup(1)), "Nothing")
      ),
      test("insert and lookup", fn()
        val m = map/empty().insert(1, 10).insert(2, 20)
        assert-equal(m.size, 2)
        assert-equal(mi(m.lookup(1)), "Just(10)")
        assert-equal(mi(m.lookup(2)), "Just(20)")
        assert-equal(mi(m.lookup(3)), "Nothing")
      ),
      test("duplicate keys replace, they do not accumulate", fn()
        val m = map/empty().insert(1, 10).insert(1, 99)
        assert-equal(m.size, 1)
        assert-equal(mi(m.lookup(1)), "Just(99)")
      ),
      test("insert-with combines", fn()
        val m = map/empty().insert(1, 10).insert-with(1, 5, fn(old : int, new : int) old + new)
        assert-equal(mi(m.lookup(1)), "Just(15)")
      ),
      test("update only touches present keys", fn()
        val m = map/empty().insert(1, 10)
        assert-equal(mi(m.update(1, fn(v) v + 1).lookup(1)), "Just(11)")
        assert-equal(m.update(2, fn(v) v + 1).size, 1)
      ),
      test("get with a default", fn()
        val m = map/empty().insert(1, 10)
        assert-equal(m.get(1, -1), 10)
        assert-equal(m.get(2, -1), -1)
      ),
    ]),

    group("removal", [
      test("removes", fn()
        val m = map/empty().insert(1, 10).insert(2, 20).remove(1)
        assert-equal(m.size, 1)
        assert-equal(mi(m.lookup(1)), "Nothing")
        assert-equal(mi(m.lookup(2)), "Just(20)")
      ),
      test("removing an absent key is a no-op", fn()
        val m = map/empty().insert(1, 10)
        assert-equal(m.remove(99).size, 1)
      ),
      test("removing from empty is a no-op", fn()
        val m : hmap<int,int> = map/empty()
        assert-equal(m.remove(1).size, 0)
      ),
      test("remove every key in a large map", fn()
        val ks = list(1, 300)
        val m  = ks.foldl(map/empty(), fn(acc, k) acc.insert(k, k))
        val m2 = ks.foldl(m, fn(acc, k) acc.remove(k))
        assert-equal(m2.size, 0)
        assert-true(m2.is-balanced)
      ),
    ]),

    group("collisions", [
      test("distinct keys with the same hash all survive", fn()
        val m = [1,2,3,4,5,6].foldl(map/empty(), fn(acc, i) acc.insert(Clashing(i), i * 10))
        assert-equal(m.size, 6)
        assert-equal(mi(m.lookup(Clashing(4))), "Just(40)")
        assert-equal(mi(m.lookup(Clashing(7))), "Nothing")
      ),
      test("removal from a bucket keeps the others", fn()
        val m = [1,2,3,4].foldl(map/empty(), fn(acc, i) acc.insert(Clashing(i), i))
        val m2 = m.remove(Clashing(1))
        assert-equal(m2.size, 3)
        assert-equal(mi(m2.lookup(Clashing(1))), "Nothing")
        assert-equal(mi(m2.lookup(Clashing(4))), "Just(4)")
      ),
      test("replacing inside a bucket does not grow it", fn()
        val m = [1,4].foldl(map/empty(), fn(acc, i) acc.insert(Clashing(i), i))
        val m2 = m.insert(Clashing(4), 99)
        assert-equal(m2.size, 2)
        assert-equal(mi(m2.lookup(Clashing(4))), "Just(99)")
      ),
    ]),

    group("iteration and conversion", [
      test("list round trips", fn()
        val m = map/hmap([(1,10), (2,20), (3,30)])
        assert-equal(m.size, 3)
        assert-equal(m.keys.length, 3)
        assert-equal(m.values.length, 3)
      ),
      test("iteration order is ascending hash", fn()
        // with hash = identity for ints, that is ascending key order
        val m = map/hmap([(3,30), (1,10), (2,20)])
        assert-equal(m.keys.show, [1,2,3].show)
      ),
      test("map over values", fn()
        val m = map/hmap([(1,10), (2,20)]).map(fn(v) v + 1)
        assert-equal(mi(m.lookup(1)), "Just(11)")
        assert-equal(mi(m.lookup(2)), "Just(21)")
      ),
      test("filter", fn()
        val m = map/hmap([(1,10), (2,20), (3,30)]).filter(fn(_k, v) v > 15)
        assert-equal(m.size, 2)
        assert-equal(mi(m.lookup(1)), "Nothing")
      ),
      test("foreach visits every entry", fn()
        var total := 0
        map/hmap([(1,10), (2,20)]).foreach(fn(_k, v) total := total + v)
        assert-equal(total, 30)
      ),
    ]),

    group("equality", [
      test("same contents, different insertion order", fn()
        val a = map/hmap([(1,10), (2,20), (3,30)])
        val b = map/hmap([(3,30), (1,10), (2,20)])
        assert-true(a == b)
      ),
      test("different values", fn()
        assert-false(map/hmap([(1,10)]) == map/hmap([(1,11)]))
      ),
      test("different sizes", fn()
        assert-false(map/hmap([(1,10)]) == map/hmap([(1,10), (2,20)]))
      ),
      test("empty equals empty", fn()
        val a : hmap<int,int> = map/empty()
        val b : hmap<int,int> = map/empty()
        assert-true(a == b)
      ),
    ]),

    group("invariants", [
      test("balanced and ordered after many inserts", fn()
        val m = list(1, 500).foldl(map/empty(), fn(acc, i) acc.insert(i, i))
        assert-equal(m.size, 500)
        assert-true(m.is-balanced, "tree is not weight balanced")
        assert-true(m.is-ordered, "node hashes are not strictly increasing")
      ),
      test("balanced after inserts in descending order", fn()
        val m = list(1, 500).reverse.foldl(map/empty(), fn(acc, i) acc.insert(i, i))
        assert-true(m.is-balanced)
        assert-true(m.is-ordered)
      ),
      test("balanced after interleaved insert and remove", fn()
        var m := map/empty()
        var i := 0
        while { i < 400 }
          m := m.insert(i, i)
          if i % 3 == 0 && i > 0 then m := m.remove(i - 1)
          i := i + 1
        assert-true(m.is-balanced)
        assert-true(m.is-ordered)
      ),
    ]),

    group("properties", [
      test("insert then lookup", fn()
        check(gen-list(gen-int(0, 200)), insert-then-lookup)
      ),
      test("removing everything empties the map", fn()
        check(gen-list(gen-int(0, 200)), remove-all-empties)
      ),
      test("stays balanced and ordered", fn()
        check(gen-list(gen-int(-500, 500)), stays-balanced)
      ),
      test("agrees with an association-list reference", fn()
        check(gen-list(gen-pair(gen-int(0, 50), gen-int())), ops-agree)
      ),
    ]),
  ])
