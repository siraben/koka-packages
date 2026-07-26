import kktest/assert
import kktest/runner
import kktest/random
import std/num/int64

fun main()
  run-tests([
    test("deterministic from a seed", fn()
      val (_, a) = rng(42).next
      val (_, b) = rng(42).next
      assert-equal(a.show, b.show)
    ),
    test("different seeds differ", fn()
      val (_, a) = rng(1).next
      val (_, b) = rng(2).next
      assert-not-equal(a.show, b.show)
    ),
    test("below is in range", fn()
      var r := rng(7)
      var i := 0
      while { i < 200 } 
        val (r2, v) = r.next-below(10)
        r := r2
        assert-true(v >= 0 && v < 10, "out of range: " ++ v.show)
        i := i + 1
    ),
  ])
