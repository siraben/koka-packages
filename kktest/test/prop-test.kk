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
      // `-1000000` and `1000000` were the default bounds *and* the flag for
      // "the caller gave no bound", so a caller who asked for exactly those
      // was silently given the size budget's range instead.  Nothing failed;
      // the properties just stopped covering what they said they covered.
      test("an explicit range is used as given, even at the old defaults", fn()
        check(gen-int(-1000000, -999000), fn(x) x >= -1000000 && x <= -999000)
        check(gen-int(999000, 1000000), fn(x) x >= 999000 && x <= 1000000)
      ),
      test("an absent bound is the size budget's to choose", fn()
        // `check` runs at size `max-size` at the widest, so that bounds the
        // default range -- which is the whole point of the size.
        check(gen-int(), fn(x) x >= -20 && x <= 20, max-size = 20)
        check(gen-int(hi = Just(0)), fn(x) x >= -20 && x <= 0, max-size = 20)
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
      // A property that throws is a failed check rather than a crash in the
      // harness -- and the exception is the diagnosis, so the report has to
      // carry it.  Reporting "property failed" with a counterexample and no
      // cause is what this pins down.
      test("a throwing property counts as failure", fn()
        match try({ check(gen-int(), fn(_) throw("boom")) })
          Ok(_)     -> assert-fail("expected the check to fail")
          Error(ex) ->
            assert-true(ex.is-assertion,
                        "a throwing property should fail the check, not crash it")
            assert-true(ex.message.contains("property threw"),
                        "the report should say the property threw:\n  " ++ ex.message)
            assert-true(ex.message.contains("boom"),
                        "the report should name the cause:\n  " ++ ex.message)
      ),
    ]),
  ])
