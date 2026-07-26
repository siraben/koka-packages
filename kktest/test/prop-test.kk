import kktest/assert
import kktest/runner
import kktest/prop

fun main()
  run-tests([
    group("property testing", [
      test("reverse is an involution", fn()
        check(gen-list(gen-int()), fn(xs) xs.reverse.reverse == xs)
      ),
      test("length is preserved by reverse", fn()
        check(gen-list(gen-int()), fn(xs) xs.reverse.length == xs.length)
      ),
      test("string append length", fn()
        check(gen-pair(gen-string(), gen-string()),
              fn(p) (p.fst ++ p.snd).count == p.fst.count + p.snd.count)
      ),
      test("nat is never negative", fn()
        check(gen-nat(), fn(n) n >= 0)
      ),
    ]),
    group("shrinking", [
      // A property that fails for any list containing an element > 5.
      // Shrinking must report a small counterexample, not the raw random one.
      test("reports a shrunk counterexample", fn()
        assert-throws(
          { check(gen-list(gen-int(0, 100)), fn(xs) xs.all(fn(x) x <= 5), runs = 200) },
          containing = "counterexample")
      ),
      test("a throwing property counts as failure", fn()
        assert-throws({ check(gen-int(), fn(_) throw("boom")) },
                      containing = "property failed")
      ),
    ]),
  ])
