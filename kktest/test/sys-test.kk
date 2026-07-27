import kktest/assert
import kktest/runner
import kktest/sys
import kktest/tmp

fun main()
  run-tests([
    test("temporary directory primitives", fn()
      val d = make-temp-dir("kktest-selftest")
      assert-true(path-exists(d), "temp dir was not created")
      remove-tree(d)
      assert-false(path-exists(d), "temp dir was not removed")
      remove-tree(d)
    ),
    test("scoped temporary directory is cleaned", fn()
      val seen = with-temp-dir(fn(d) {
        assert-true(path-exists(d))
        d
      })
      assert-false(path-exists(seen), "with-temp-dir leaked its directory")
    ),
    test("scoped temporary directory cleans after failure", fn()
      assert-throws(fn() {
        with-temp-dir(fn(d) {
          assert-true(path-exists(d))
          throw("deliberate")
        })
      }, containing = "deliberate")
    ),
    test("monotonic clock does not go backwards", fn()
      val t0 = mono-ms()
      val t1 = mono-ms()
      assert-at-most(t0, t1)
    ),
  ])
