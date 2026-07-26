import kktest/assert
import kktest/runner
import resource/scope

// A fake resource that records what happened to it, so the tests can assert
// on release order and count rather than on side effects in the world.
struct tracker
  log : ref<global, list<string>>

fun tracker() : io tracker
  Tracker(ref([]))

fun note( t : tracker, s : string ) : io ()
  val l = t.log
  l := Cons(s, !l)

fun events( t : tracker ) : io list<string>
  (!t.log).reverse

fun open-fake( t : tracker, name : string ) : io string
  t.note("open " ++ name)
  name

fun close-fake( t : tracker, name : string ) : io ()
  t.note("close " ++ name)

// An effect whose handler abandons the continuation, which is how
// cancellation unwinds.
effect ctl abort( reason : string ) : a

fun with-abort( action : () -> <abort|e> a ) : e maybe<a>
  with ctl abort(_r) Nothing
  Just(action())

// Bodies that need several statements are named: a multi-statement `fn`
// nested inside a call argument does not lay out cleanly.
fun partial-init( t : tracker ) : io ()
  with-scope fn(s)
    s.acquire({ open-fake(t, "a") }, fn(x) close-fake(t, x))
    throw("failed halfway")
    s.acquire({ open-fake(t, "b") }, fn(x) close-fake(t, x))
    ()

fun failing-release( t : tracker ) : io ()
  with-scope fn(s)
    s.acquire({ open-fake(t, "a") }, fn(x) close-fake(t, x))
    s.acquire({ open-fake(t, "b") }, fn(_x) throw("release failed"))
    ()

fun body-and-release-fail( t : tracker ) : io ()
  with-scope fn(s)
    s.acquire({ open-fake(t, "a") }, fn(_x) throw("release failed"))
    throw("body failed")

fun main()
  run-tests([
    group("with-resource", [
      test("releases on success", fn()
        val t = tracker()
        val r = with-resource({ open-fake(t, "a") }, fn(x) close-fake(t, x), fn(x) x ++ "!")
        assert-equal(r, "a!")
        assert-equal(t.events.show, ["open a", "close a"].show)
      ),
      test("releases on exception, and the exception propagates", fn()
        val t = tracker()
        assert-throws(
          { with-resource({ open-fake(t, "a") }, fn(x) close-fake(t, x), fn(_x) throw("boom")) },
          containing = "boom")
        assert-equal(t.events.show, ["open a", "close a"].show)
      ),
      test("releases when a handler discards the continuation", fn()
        // this is the cancellation path: the body never returns
        val t = tracker()
        val r = with-abort fn()
          with-resource({ open-fake(t, "a") }, fn(x) close-fake(t, x), fn(_x) abort("cancelled"))
        assert-true(r.is-nothing)
        assert-equal(t.events.show, ["open a", "close a"].show)
      ),
      test("nested scopes release inner first", fn()
        val t = tracker()
        with-resource({ open-fake(t, "outer") }, fn(x) close-fake(t, x), fn(_o)
          with-resource({ open-fake(t, "inner") }, fn(x) close-fake(t, x), fn(_i) ())
        )
        assert-equal(t.events.show,
                     ["open outer", "open inner", "close inner", "close outer"].show)
      ),
      test("release runs exactly once", fn()
        val t = tracker()
        with-resource({ open-fake(t, "a") }, fn(x) close-fake(t, x), fn(_x) ())
        assert-equal(t.events.filter(fn(e) e == "close a").length, 1)
      ),
    ]),

    group("owned handles", [
      test("value is usable before release", fn()
        val t = tracker()
        with-owned({ open-fake(t, "a") }, fn(x) close-fake(t, x), fn(h)
          assert-equal(h.with-value(fn(x) x), "a")
          assert-false(h.is-released)
        )
      ),
      test("release is idempotent", fn()
        val t = tracker()
        with-owned({ open-fake(t, "a") }, fn(x) close-fake(t, x), fn(h)
          h.release-owned
          h.release-owned
          assert-true(h.is-released)
        )
        // one close from the explicit releases, none from scope exit
        assert-equal(t.events.filter(fn(e) e == "close a").length, 1)
      ),
      test("use after release throws", fn()
        val t = tracker()
        with-owned({ open-fake(t, "a") }, fn(x) close-fake(t, x), fn(h)
          h.release-owned
          assert-throws({ h.with-value(fn(x) x) }, containing = "use after release")
          assert-throws({ h.get }, containing = "use after release")
        )
      ),
      test("an early release still leaves the scope consistent", fn()
        val t = tracker()
        with-owned({ open-fake(t, "a") }, fn(x) close-fake(t, x), fn(h) h.release-owned)
        assert-equal(t.events.show, ["open a", "close a"].show)
      ),
    ]),

    group("scopes", [
      test("releases everything in reverse order", fn()
        val t = tracker()
        with-scope fn(s)
          s.acquire({ open-fake(t, "a") }, fn(x) close-fake(t, x))
          s.acquire({ open-fake(t, "b") }, fn(x) close-fake(t, x))
          s.acquire({ open-fake(t, "c") }, fn(x) close-fake(t, x))
          ()
        assert-equal(t.events.show,
                     ["open a","open b","open c","close c","close b","close a"].show)
      ),
      test("partial initialisation releases only what was acquired", fn()
        val t = tracker()
        assert-throws({ partial-init(t) }, containing = "failed halfway")
        assert-equal(t.events.show, ["open a", "close a"].show)
      ),
      test("on-exit runs without acquiring", fn()
        val t = tracker()
        with-scope fn(s)
          s.on-exit({ t.note("exit hook") })
          ()
        assert-equal(t.events.show, ["exit hook"].show)
      ),
      test("a failing release does not stop the others", fn()
        val t = tracker()
        assert-throws({ failing-release(t) }, containing = "release failed")
        // 'a' was still closed even though closing 'b' threw
        assert-true(t.events.any(fn(e) e == "close a"))
      ),
      test("one of the two failures is always reported", fn()
        // documented `finally` semantics: the release failure replaces the
        // body failure.  What must never happen is *neither* being reported.
        val t = tracker()
        match try({ body-and-release-fail(t) })
          Error(ex) ->
            assert-true(ex.message.contains("release failed") ||
                        ex.message.contains("body failed"),
                        "expected one of the two failures, got: " ++ ex.message)
          Ok(_) -> assert-fail("expected an exception")
      ),

      test("nested scopes", fn()
        val t = tracker()
        with-scope fn(outer)
          outer.acquire({ open-fake(t, "outer") }, fn(x) close-fake(t, x))
          with-scope fn(inner)
            inner.acquire({ open-fake(t, "inner") }, fn(x) close-fake(t, x))
            ()
        assert-equal(t.events.show,
                     ["open outer","open inner","close inner","close outer"].show)
      ),
      test("many resources in one scope", fn()
        val t = tracker()
        with-scope fn(s)
          list(1, 100).foreach fn(i)
            s.acquire({ open-fake(t, i.show) }, fn(x) close-fake(t, x))
            ()
        assert-equal(t.events.length, 200)
      ),
    ]),
  ])
