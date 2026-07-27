import kktest/assert
import kktest/runner
import bytes/bytes
import runtime/loop

// Drive libuv until at least one completion is available.  The bound turns a
// broken callback into a test failure instead of a hung test process.
fun drive( turns : int = 20 ) : io ()
  if pending() > 0 then ()
  elif turns <= 0 then throw("the event loop produced no completion")
  else
    run-once(100)
    drive(turns - 1)

fun completion-for( wanted : int ) : io completion
  drive()
  match next-completion()
    Just(c) ->
      if c.request == wanted then c
      else throw("completion belonged to request " ++ c.request.show ++
                 ", expected " ++ wanted.show)
    Nothing -> throw("pending reported a completion but the queue was empty")

fun clear-completions() : io ()
  match next-completion()
    Just(_) -> clear-completions()
    Nothing -> ()

fun main()
  loop-init()
  clear-completions()
  run-tests([
    group("request ids", [
      test("ids are positive and never immediately reused", fn()
        val a = fresh-request()
        val b = fresh-request()
        assert-true(a > 0)
        assert-true(b > a, a.show ++ " then " ++ b.show)
      ),
    ]),

    group("completion queue", [
      test("an empty queue reports Nothing", fn()
        assert-equal(pending(), 0)
        assert-true(next-completion().is-nothing)
      ),
      test("a timer produces one successful completion", fn()
        val before = live-timers()
        val req = fresh-request()
        assert-equal(arm-timer(req, 0), 0)
        assert-equal(live-timers(), before + 1)
        val c = completion-for(req)
        assert-equal(c.status, 0)
        assert-true(c.error.is-nothing)
        assert-equal(c.data.length, 0)
        assert-equal(live-timers(), before)
        assert-equal(pending(), 0)
      ),
      test("cancelling a timer is idempotent and produces no completion", fn()
        val before = live-timers()
        val req = fresh-request()
        assert-equal(arm-timer(req, 60000), 0)
        cancel-timer(req)
        cancel-timer(req)
        run-once(0)
        assert-equal(live-timers(), before)
        assert-equal(pending(), 0)
      ),
    ]),

    group("errors", [
      test("invalid handles return a structured libuv error", fn()
        match bound-port(-999999)
          Left(e) ->
            assert-true(e.status < 0)
            assert-true(e.message.is-notempty)
          Right(p) -> assert-fail("an invalid handle reported port " ++ p.show)
      ),
      test("check-uv preserves operation context", fn()
        assert-throws({ check-uv(-1, "opening test resource") },
                      containing = "opening test resource")
      ),
    ]),

    group("listener primitives", [
      test("listen exposes an ephemeral port and close is idempotent", fn()
        val l = listen("127.0.0.1", 0)
        assert-true(is-open(l))
        match bound-port(l)
          Left(e) -> assert-fail(e.message)
          Right(p) -> assert-true(p > 0 && p <= 65535, p.show)
        // The wrong close operation cannot close a listener.
        close-stream(l)
        assert-true(is-open(l))
        close-listener(l)
        close-listener(l)
        assert-false(is-open(l))
        val _active = run-once(0)
        ()
      ),
      test("a pending accept can be cancelled and re-armed", fn()
        val l = listen("127.0.0.1", 0)
        val first = fresh-request()
        assert-equal(arm-accept(l, first), 0)
        cancel-accept(l)
        val c1 = completion-for(first)
        assert-true(c1.status < 0)
        assert-true(c1.error.is-just)

        val second = fresh-request()
        assert-equal(arm-accept(l, second), 0,
                     "cancelling must clear the listener's waiter")
        cancel-accept(l)
        val c2 = completion-for(second)
        assert-true(c2.status < 0)
        close-listener(l)
        val _active = run-once(0)
        ()
      ),
      test("read on a listener is refused without damaging it", fn()
        val l = listen("127.0.0.1", 0)
        val rc = arm-read(l, fresh-request(), 64)
        assert-true(rc < 0)
        assert-true(is-open(l))
        close-listener(l)
        val _active = run-once(0)
        ()
      ),
    ]),
  ])
