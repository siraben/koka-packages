import kktest/assert
import kktest/runner

fun main()
  run-tests([
    test("booleans and equality", fn()
      assert-true(True)
      assert-false(False)
      assert-equal(1 + 1, 2)
      assert-not-equal("a", "b")
    ),
    test("string containment", fn()
      assert-contains("mature package", "package")
      assert-not-contains("mature package", "prototype")
      assert-throws(fn() assert-contains("abc", "xyz"), containing = "xyz")
    ),
    test("maybe extraction", fn()
      val x = assert-just(Just(42))
      assert-equal(x, 42)
      assert-nothing(Nothing : maybe<int>)
      assert-throws(fn() assert-just(Nothing : maybe<int>), containing = "Nothing")
      assert-throws(fn() assert-nothing(Just(7)), containing = "Just(7)")
    ),
    test("ordering", fn()
      assert-less(3, 4)
      assert-at-most(4, 4)
      assert-at-most(3, 4)
      assert-throws(fn() assert-less(4, 4), containing = "4 < 4")
    ),
    test("exception assertions", fn()
      assert-throws({ throw("boom") }, containing = "boom")
      val x = assert-ok({ 42 })
      assert-equal(x, 42)
    ),
  ])
