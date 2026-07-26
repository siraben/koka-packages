import kktest/assert
import kktest/runner

fun main()
  run-tests([
    test("arithmetic", fn()
      assert-equal(2 + 2, 4)
    ),
    group("strings", [
      test("concat", fn() assert-equal("a" ++ "b", "ab")),
      test("empty",  fn() assert-true("".is-empty)),
    ]),
    test("known broken", fn() assert-true(False), expect-fail = True),
  ])
