import kktest/assert
import kktest/runner
import runtime/loop
import runtime/task
import resource/scope

fun log() : io ref<global, list<string>>
  ref([])

// Position of an event in the recorded order, or -1.  Ordering is the point:
// "release happened" is satisfied at t=0 by a release that fired far too early.
fun index-of-event( parts : list<string>, name : string ) : int
  fun go( xs : list<string>, i : int ) : int
    match xs
      Nil -> -1
      Cons(x, rest) -> if x == name then i else go(rest, i + 1)
  go(parts, 0)

fun note( l : ref<global, list<string>>, s : string ) : io ()
  l := Cons(s, !l)

fun events( l : ref<global, list<string>> ) : io list<string>
  (!l).reverse

// ---------------------------------------------------------------------------

fun child-succeeds() : io string
  with-task-group fn(_g)
    val l = log()
    l.note("parent")
    spawn(fn()
      l.note("child")
    )
    // give the child a turn
    yield()
    l.note("after")
    l.events.join(",")

fun child-fails() : io ()
  with-task-group fn(_g)
    spawn(fn() throw("child exploded"))
    sleep(20)
    ()

fun sibling-cancelled() : io string
  val l = log()
  match try({ run-siblings(l) })
    Error(_) -> l.events.join(",")
    Ok(_)    -> "no failure"

fun run-siblings( l : ref<global, list<string>> ) : io ()
  with-task-group fn(_g)
    spawn(fn()
      // a long sleeper that must be cancelled when its sibling fails
      l.note("sleeper start")
      sleep(5000)
      l.note("sleeper finished")     // must not happen
    )
    spawn(fn()
      sleep(10)
      throw("boom")
    )
    sleep(50)
    ()

// Cancelling the group cancels *every* task in it, including the root, so the
// root's own next suspension point raises.  The log is kept outside the group
// so it survives that.
fun parent-cancels() : io string
  val l = log()
  match try({ run-cancelling(l) })
    Error(ex) ->
      if is-cancellation(ex) then l.events.join(",")
      else throw-exn(ex)
    Ok(_) -> l.events.join(",")

fun run-cancelling( l : ref<global, list<string>> ) : io ()
  with-task-group fn(g)
    spawn(fn()
      l.note("worker start")
      sleep(5000)
      l.note("worker finished")      // must not happen
    )
    sleep(20)
    g.cancel
    yield()

fun cleanup-on-cancel() : io string
  val l = log()
  match try({ run-cleanup(l) })
    Error(ex) ->
      if is-cancellation(ex) then l.events.join(",")
      else throw-exn(ex)
    Ok(_) -> l.events.join(",")

// `with-async-resource`, not `with-resource`: inside a task the latter's
// `finally` fires at the first suspension point, so "release" was already in
// the log before `g.cancel` was even reached and the test passed whether or
// not cancellation worked.  The marker below is what makes the ordering
// observable.
fun run-cleanup( l : ref<global, list<string>> ) : io ()
  with-task-group fn(g)
    spawn(fn()
      with-async-resource({ l.note("acquire") }, fn(_x) l.note("release"), fn(_x)
        sleep(5000)
      )
    )
    sleep(20)
    l.note("cancel")
    g.cancel
    yield()

fun nested-groups() : io string
  val l = log()
  with-task-group fn(_g)
    l.note("outer")
    val inner = with-task-group fn(_g2)
                  l.note("inner")
                  spawn(fn() l.note("inner child"))
                  yield()
                  "inner done"
    l.note(inner)
    l.events.join(",")

// Reading a `ref` inline inside a function that carries the `async` effect
// leaves koka 3.2.7's inference with a heap-divergence constraint it cannot
// discharge (it fails with an internal error).  Monomorphic `io` helpers avoid
// it; see doc/dev/work-log.md.
fun bump( r : ref<global,int> ) : io ()
  r := !r + 1

fun read-int( r : ref<global,int> ) : io int
  !r

fun many-tasks( n : int ) : io int
  with-task-group fn(_g)
    val counter = ref(0)
    spawn-n(n, counter)
    // let them all run
    sleep(5)
    read-int(counter)

fun spawn-n( n : int, counter : ref<global,int> ) : <async|io> ()
  if n <= 0 then ()
  else
    spawn(fn() bump(counter))
    spawn-n(n - 1, counter)

fun timer-fires() : io int
  with-task-group fn(_g)
    val t0 = now-ms()
    sleep(60)
    now-ms() - t0

fun timeout-expires() : io string
  with-task-group fn(_g)
    // a request that will never complete: a timer far in the future
    val never = fresh-request()
    arm-timer(never, 100000)
    match await-within(never, 30)
      Nothing -> "timed out"
      Just(_) -> "completed"

fun timeout-does-not-expire() : io string
  with-task-group fn(_g)
    val soon = fresh-request()
    arm-timer(soon, 5)
    match await-within(soon, 1000)
      Nothing -> "timed out"
      Just(_) -> "completed"

// A deadline that *loses* its race must be stopped, not left armed.  Ten races
// the request wins, each with a deadline an hour out: if they are not stopped,
// ten `uv_timer_t` handles stay live and each later fires a completion nobody
// is parked on.
fun losing-deadlines-are-stopped() : io int
  with-task-group fn(_g)
    val before = live-timers()
    fun go( i : int ) : <async|io> ()
      if i >= 10 then ()
      else
        val now = fresh-request()
        check-uv(arm-timer(now, 0), "cannot start a timer")
        match await-within(now, 3600000)
          Just(_) -> go(i + 1)
          Nothing -> throw("an hour-long deadline beat a 0 ms timer")
    go(0)
    live-timers() - before

// The same obligation on the other suspension point that owns a timer: a
// cancelled `sleep` has to stop the one it armed.
fun a-cancelled-sleep-stops-its-timer() : io int
  with-task-group fn(_g)
    val before = live-timers()
    with-task-group fn(_inner)
      spawn(fn() sleep(3600000))
      yield()                       // let the child reach the park
    live-timers() - before

fun main()
  run-tests([
    group("tasks", [
      test("a spawned child runs", fn()
        assert-equal(child-succeeds(), "parent,child,after")
      ),
      test("a child failure propagates to the parent", fn()
        assert-throws({ child-fails() }, containing = "child exploded")
      ),
      test("a failing task cancels its siblings", fn()
        val e = sibling-cancelled()
        assert-true(e.contains("sleeper start"), "the sleeper never started: " ++ e)
        assert-false(e.contains("sleeper finished"),
                     "the sleeper outlived its sibling's failure: " ++ e)
      ),
      test("the parent can cancel the group", fn()
        val e = parent-cancels()
        assert-true(e.contains("worker start"))
        assert-false(e.contains("worker finished"), "the worker was not cancelled: " ++ e)
      ),
      // `with-resource`, not `with-async-resource`: this pins the scheduler's
      // use of `rawctl`.  Under `ctl` the release fires at the first
      // suspension point and again when the task unwinds, which for a socket
      // is a use-after-close followed by a double-close.
      test("a resource held across a suspension point is released once, at the end", fn()
        val l = log()
        with-task-group fn(_g)
          spawn(fn()
            with-resource({ l.note("acquire") }, fn(_x) l.note("release"), fn(_x)
              sleep(20)
              l.note("body-done")
            )
          )
          sleep(80)
        val e = l.events.join(",")
        assert-equal(e, "acquire,body-done,release", e)
      ),
      // An ordinary failure whose message happens to read "task cancelled"
      // must not be mistaken for one.  That decision picks whether a failing
      // task takes its whole group down, so it cannot rest on prose a handler
      // might echo from a request.
      test("a failure that merely says \"task cancelled\" is not one", fn()
        assert-false(is-cancellation(Exception(cancelled-message, ExnError)))
        assert-true(is-cancellation(Exception("anything at all", ExnCancelled)))
      ),
      test("resources are released when a task is cancelled", fn()
        val e = cleanup-on-cancel()
        val parts = e.split(",")
        assert-true(e.contains("acquire"), e)
        assert-true(e.contains("release"), "the resource was not released: " ++ e)
        // release must come *after* cancellation, not at the first suspension
        assert-true(index-of-event(parts, "release") > index-of-event(parts, "cancel"),
                    "the resource was released before cancellation: " ++ e)
        // and exactly once: a double release is a double close
        assert-equal(parts.filter(fn(x) x == "release").length, 1, e)
      ),
      test("groups nest", fn()
        val e = nested-groups()
        assert-true(e.contains("outer"))
        assert-true(e.contains("inner"))
        assert-true(e.contains("inner child"))
        assert-true(e.contains("inner done"))
      ),
      test("many short-lived tasks all run", fn()
        assert-equal(many-tasks(500), 500)
      , timeout-s = 60),
    ]),

    group("timers", [
      test("sleep waits at least as long as asked", fn()
        val elapsed = timer-fires()
        assert-true(elapsed >= 55, "slept only " ++ elapsed.show ++ "ms")
        assert-true(elapsed < 3000, "slept far too long: " ++ elapsed.show ++ "ms")
      ),
      test("a deadline that passes reports a timeout", fn()
        assert-equal(timeout-expires(), "timed out")
      ),
      test("a deadline that does not pass reports completion", fn()
        assert-equal(timeout-does-not-expire(), "completed")
      ),
      test("a deadline that loses its race is stopped", fn()
        assert-equal(losing-deadlines-are-stopped(), 0,
                     "losing deadlines were left armed in the loop")
      ),
      test("a cancelled sleep stops its timer", fn()
        assert-equal(a-cancelled-sleep-stops-its-timer(), 0,
                     "a cancelled sleep left its timer armed")
      ),
    ]),
  ])
