import kktest/assert
import kktest/runner
import kktest/prop
import hashmap/set

fun int/hash( i : int ) : int
  i

// insertion sort: small inputs only, and it keeps the test free of
// assumptions about what the standard library provides
fun isort( xs : list<int> ) : div list<int>
  xs.foldl([], fn(acc, x) insert-sorted(acc, x))

fun insert-sorted( xs : list<int>, x : int ) : div list<int>
  match xs
    Nil -> [x]
    Cons(y, rest) -> if x <= y then Cons(x, xs) else Cons(y, insert-sorted(rest, x))

fun sorted( s : hset<int> ) : div string
  s.list.isort.show

// set laws, checked against list operations
fun union-is-commutative( p : (list<int>, list<int>) ) : div bool
  set/(==)(union(hset(p.fst), hset(p.snd)), union(hset(p.snd), hset(p.fst)))

fun intersect-is-commutative( p : (list<int>, list<int>) ) : div bool
  set/(==)(intersect(hset(p.fst), hset(p.snd)), intersect(hset(p.snd), hset(p.fst)))

fun difference-removes( p : (list<int>, list<int>) ) : div bool
  val d = difference(hset(p.fst), hset(p.snd))
  d.list.all(fn(x) !hset(p.snd).member(x)) &&
    p.fst.all(fn(x) hset(p.snd).member(x) || d.member(x))

fun union-is-a-superset( p : (list<int>, list<int>) ) : div bool
  val u = union(hset(p.fst), hset(p.snd))
  subset(hset(p.fst), u) && subset(hset(p.snd), u)

fun no-duplicates( xs : list<int> ) : div bool
  hset(xs).size == xs.foldl([], fn(acc : list<int>, x) if acc.any(fn(y) y == x) then acc else Cons(x, acc)).length

fun main()
  run-tests([
    group("basics", [
      test("empty", fn()
        val s : hset<int> = set/empty()
        assert-equal(s.size, 0)
        assert-true(s.is-empty)
        assert-false(s.member(1))
      ),
      test("insert and member", fn()
        val s = set/empty().insert(1).insert(2)
        assert-equal(s.size, 2)
        assert-true(s.member(1))
        assert-false(s.member(3))
      ),
      test("inserting twice does not grow the set", fn()
        assert-equal(set/empty().insert(1).insert(1).size, 1)
      ),
      test("remove", fn()
        val s = hset([1,2,3]).remove(2)
        assert-equal(s.size, 2)
        assert-false(s.member(2))
      ),
      test("removing an absent element is a no-op", fn()
        assert-equal(hset([1]).remove(9).size, 1)
      ),
    ]),

    group("operations", [
      test("union", fn()
        assert-equal(sorted(union(hset([1,2]), hset([2,3]))), [1,2,3].show)
      ),
      test("intersect", fn()
        assert-equal(sorted(intersect(hset([1,2,3]), hset([2,3,4]))), [2,3].show)
      ),
      test("difference", fn()
        assert-equal(sorted(difference(hset([1,2,3]), hset([2]))), [1,3].show)
      ),
      test("subset", fn()
        assert-true(subset(hset([1,2]), hset([1,2,3])))
        assert-false(subset(hset([1,4]), hset([1,2,3])))
        assert-true(subset(set/empty(), hset([1])))
      ),
      test("equality ignores insertion order", fn()
        assert-true(set/(==)(hset([1,2,3]), hset([3,1,2])))
        assert-false(set/(==)(hset([1,2]), hset([1,2,3])))
      ),
    ]),

    group("properties", [
      test("union is commutative", fn()
        check(gen-pair(gen-list(gen-int(0,50)), gen-list(gen-int(0,50))), union-is-commutative)
      ),
      test("intersect is commutative", fn()
        check(gen-pair(gen-list(gen-int(0,50)), gen-list(gen-int(0,50))), intersect-is-commutative)
      ),
      test("difference removes exactly the second set", fn()
        check(gen-pair(gen-list(gen-int(0,50)), gen-list(gen-int(0,50))), difference-removes)
      ),
      test("a union contains both operands", fn()
        check(gen-pair(gen-list(gen-int(0,50)), gen-list(gen-int(0,50))), union-is-a-superset)
      ),
      test("a set holds no duplicates", fn()
        check(gen-list(gen-int(0,20)), no-duplicates)
      ),
    ]),
  ])
