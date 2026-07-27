/* Structured concurrency: scoped task groups, spawn, await, cancellation.

   ## The model

   The `async` effect has one primitive, `await-request`: suspend the current
   task until a named event-loop request completes.  `spawn` starts a sibling
   task in the same scope.  Everything else -- sleep, timeout, race, socket
   reads -- is written in terms of those two.

   The scheduler is an effect handler.  `await-request` captures its
   continuation and files it under the request id; the run loop drives libuv,
   drains completions, and resumes the matching continuations.  Tasks are
   cooperative and single threaded, so no task can be preempted between two
   statements and there are no data races by construction.

   ## Structure

   > A child task does not outlive its scope.

   `with-task-group` returns when the *root* task -- the body -- is done.  Any
   sibling still running at that point is **cancelled and then awaited**, not
   joined: a task doing useful work when the body returns is stopped, it does
   not get to finish.  Spawn work you need the result of, and await it, rather
   than assuming the group will wait.  There is no `detach` in this version.

   Draining gives up after 10000 rounds.  A task that never reaches a
   suspension point cannot be cancelled by a cooperative scheduler, and the
   alternative to giving up is hanging forever; a task parked at that point
   never runs its cleanups.  It is a known limitation, not a guarantee.

   ## Cancellation

   Cancellation is *not* an exception: it is a flag plus a rule.  A cancelled
   task is resumed one last time with `Cancelled`, and every suspension point
   turns that into a `cancelled` exception, which unwinds through `finally` and
   therefore through every `resource/scope` release.  That is why cleanup is
   correct under cancellation without any special case.

   A task that is already suspended on a socket read is woken because closing
   the stream completes its pending request; see `runtime/loop`.

   ## Failure propagation

   A task that throws records its exception in the group.  When the group
   finishes, the first recorded failure is re-raised in the parent, after every
   sibling has been cancelled and awaited.  A failure therefore cannot be lost
   and cannot leave siblings running.
*/
module runtime/task

import std/num/int64
import bytes/bytes
import runtime/loop

// What a suspended task is resumed with.
pub type wakeup
  Completed( result : completion )
  Cancelled

// The async effect.  `div` because a task's continuation is stored and
// resumed, which the type checker cannot see as structurally decreasing.
pub div effect async
  // Suspend until one of `requests` completes, or until this task is
  // cancelled.  Waiting on several at once is what makes a timeout a race
  // rather than a poll.
  ctl await-requests( requests : list<int> ) : wakeup
  // Start a sibling task in the current group.
  ctl spawn-task( body : () -> <async|io> () ) : ()
  // Yield to other ready tasks without waiting for anything.
  ctl yield-now() : ()
  // Has this task been asked to stop?
  ctl cancel-requested() : bool
  // Register an action to run when *this task* ends, however it ends.
  ctl defer( action : () -> io () ) : ()

// ----------------------------------------------------------------------------
// scheduler state
// ----------------------------------------------------------------------------

// A suspended task, waiting to be handed a wakeup.
alias resumption = (wakeup) -> io ()

struct sched
  // tasks that can run right now
  ready    : ref<global, list<() -> io ()>>
  // tasks suspended on one or more request ids
  waiting  : ref<global, list<(list<int>, resumption)>>
  // number of tasks started and not yet finished
  live     : ref<global, int>
  // set when the group is cancelling; every suspension point observes it
  cancelling : ref<global, bool>
  // the first failure seen, re-raised in the parent
  failure  : ref<global, maybe<exception>>
  // set when the group's *root* task has finished; that, not a headcount, is
  // when the group is over
  root-done : ref<global, bool>

fun sched() : io sched
  Sched(ref([]), ref([]), ref(0), ref(False), ref(Nothing), ref(False))

// Monomorphic accessors for the scheduler's mutable state.
//
// These exist because reading a `ref` inline inside an effect-handler body
// leaves the inference engine with heap-divergence constraints it cannot
// discharge (it fails with an internal error on koka 3.2.7).  Wrapping each
// read in a function with a concrete type fixes them at the definition.
fun is-cancelling-now( s : sched ) : io bool
  val c = s.cancelling
  !c

fun set-cancelling( s : sched ) : io ()
  val c = s.cancelling
  c := True

fun live-count( s : sched ) : io int
  val l = s.live
  !l

fun add-live( s : sched, n : int ) : io ()
  val l = s.live
  l := !l + n

fun failure-of( s : sched ) : io maybe<exception>
  val f = s.failure
  !f

fun is-root-done( s : sched ) : io bool
  val d = s.root-done
  !d

fun set-root-done( s : sched ) : io ()
  val d = s.root-done
  d := True


fun push-ready( s : sched, t : () -> io () ) : io ()
  val r = s.ready
  r := (!r) ++ [t]

fun take-ready( s : sched ) : io maybe<() -> io ()>
  val r = s.ready
  match !r
    Nil -> Nothing
    Cons(t, rest) -> { r := rest; Just(t) }

fun park( s : sched, requests : list<int>, k : resumption ) : io ()
  val w = s.waiting
  w := Cons((requests, k), !w)

// Remove and return the task waiting on `request`.  A task parked on several
// ids is removed entirely, so the losing request cannot wake it a second time.
fun unpark( s : sched, request : int ) : io maybe<resumption>
  val w = s.waiting
  val all = !w
  match all.filter(fn(e) e.fst.any(fn(i) i == request))
    Cons((_, k), _) ->
      w := all.filter(fn(e) !e.fst.any(fn(i) i == request))
      Just(k)
    Nil -> Nothing

fun waiting-count( s : sched ) : io int
  val w = s.waiting
  (!w).length

// Wake every parked task with `Cancelled`.  Used when the group is torn down.
fun wake-all-cancelled( s : sched ) : io ()
  val w = s.waiting
  val all = !w
  w := []
  all.foreach(fn(e) s.push-ready(fn() (e.snd)(Cancelled)))

fun record-failure( s : sched, ex : exception ) : io ()
  val f = s.failure
  match !f
    Nothing -> f := Just(ex)
    Just(_) -> ()      // the first failure is the interesting one

// ----------------------------------------------------------------------------
// running a group
// ----------------------------------------------------------------------------

// A handle on the group, for cancelling it from inside.
pub struct task-group
  state : sched

// Ask every task in the group to stop.  Tasks stop at their next suspension
// point; a task that never suspends runs to completion, which is the usual
// cooperative-cancellation caveat.
pub fun cancel( g : task-group ) : io ()
  g.state.set-cancelling
  g.state.wake-all-cancelled

pub fun is-cancelling( g : task-group ) : io bool
  g.state.is-cancelling-now

// Has the current task been asked to stop?  A long computation should check
// this and unwind, since a task that never suspends is never interrupted.
//
// (Named this way because `is-cancelled` is the generated predicate for the
// `Cancelled` constructor of `:wakeup`.)
pub fun cancellation-requested() : <async|io> bool
  cancel-requested()

// Run `body` as the root task of a fresh group.
//
// Returns when the root task is done; siblings still running are then
// cancelled and awaited, so nothing is left running -- but a sibling that had
// not finished is stopped rather than waited for.  If any task failed, the
// first failure is re-raised here, after the same cancel-and-await.
pub fun with-task-group( body : (task-group) -> <async|io> a ) : io a
  loop-init()
  val s = sched()
  val g = Task-group(s)
  // The slot is created through a helper so its element type is tied to
  // `body`'s result; `ref(Nothing)` on its own is polymorphic and Koka's value
  // restriction rejects a polymorphic value with an effect.
  val result = result-slot(body)

  s.push-ready(run-task(s, fn()
    val x = body(g)
    result := Just(x)
    s.set-root-done
  ))
  s.add-live(1)

  finally({ drain(s) }, { run-loop(s) })

  match s.failure-of
    Just(ex) -> throw-exn(ex)
    Nothing  ->
      match read-slot(result)
        Just(x) -> x
        Nothing ->
          // The root produced nothing because it was cancelled; report that as
          // a cancellation so a caller can tell an orderly stop from a bug.
          if s.is-cancelling-now then throw-exn(Exception(cancelled-message, ExnCancelled))
          else throw("the root task did not produce a result")

fun result-slot( _witness : (task-group) -> <async|io> a ) : io ref<global, maybe<a>>
  ref(Nothing)

fun read-slot( r : ref<global, maybe<a>> ) : io maybe<a>
  !r

// Wrap one task body in the scheduler's handler.
//
// Every operation is `rawctl`, not `ctl`, and that is load bearing.  A `ctl`
// handler returning without resuming tells Koka the computation was abandoned,
// so it runs the finalizers -- every enclosing `finally`, and so every
// `with-resource` release.  That is right in general and wrong here: this
// scheduler parks and resumes later, so a resource held across an await would
// be released at the suspension point and again at unwind, which for a socket
// is a use-after-close then a double-close.  `rawctl` hands the continuation
// over without finalizing.
//
// The obligation is that every captured continuation is resumed exactly once
// or its cleanups never run.  Cancellation resumes with `Cancelled` rather
// than dropping the task, which discharges it.
fun run-task( s : sched, body : () -> <async|io> () ) : io (() -> io ())
  fn()
    val cleanups : ref<global, list<() -> io ()>> = ref([])
    with handler
      rawctl await-requests(reqs)
        if s.is-cancelling-now then
          // already cancelling: do not even arm a wait
          s.push-ready(fn() rcontext.resume(Cancelled))
        else
          s.park(reqs, fn(w) rcontext.resume(w))
      rawctl spawn-task(child)
        s.add-live(1)
        s.push-ready(run-task(s, child))
        s.push-ready(fn() rcontext.resume(()))
      rawctl yield-now()
        s.push-ready(fn() rcontext.resume(()))
      rawctl cancel-requested()
        val flag = s.is-cancelling-now
        s.push-ready(fn() rcontext.resume(flag))
      rawctl defer(action)
        add-cleanup(cleanups, action)
        s.push-ready(fn() rcontext.resume(()))
    // A task's failure is the group's failure, and it cancels the siblings.
    match try({ body() })
      Error(ex) ->
        // A sibling that unwinds *because the group is already tearing down*
        // has not failed; recording it would turn an orderly shutdown into a
        // reported error in the parent.
        if !(is-cancellation(ex) && s.is-cancelling-now) then
          s.record-failure(ex)
          s.set-cancelling
          s.wake-all-cancelled
      Ok(_) -> ()
    // The task has really ended now -- not merely suspended -- so this is
    // where its resources are released, newest first.
    run-cleanups(cleanups)
    s.add-live(-1)

// Run a task's deferred actions, newest first.  A failing cleanup must not
// stop the others, so each is wrapped.
fun run-cleanups( cleanups : ref<global, list<() -> io ()>> ) : io ()
  val all = !cleanups
  cleanups := []
  all.foreach(fn(a) { try({ a() }); () })

// Monomorphic, for the same inference reason as the accessors above.
fun add-cleanup( cleanups : ref<global, list<() -> io ()>>, action : () -> io () ) : io ()
  cleanups := Cons(action, !cleanups)

// The scheduler: run ready tasks, then drive the loop for completions.
fun run-loop( s : sched ) : io ()
  match s.take-ready
    Just(t) ->
      t()
      run-loop(s)
    Nothing ->
      // The group is over when its *root* task has finished.  Siblings that
      // are still parked are then cancelled and drained by `drain`.
      //
      // Two earlier conditions were wrong in ways worth recording. A live-task
      // counter has to be decremented in exactly one place per task, and a
      // resumed continuation makes that easy to undercount. "Nothing ready and
      // nothing parked" looks safer but has a window: it is momentarily true
      // between waking a task and that task re-parking, and a server whose
      // group ends there loses its listener mid-run. The root finishing is the
      // condition `with-task-group` actually promises, and it cannot drift.
      if s.is-root-done then ()
      elif s.waiting-count == 0 then ()   // nothing can ever wake: deadlock
      else
        // Drain first, block second.  An `arm-*` can complete *synchronously*
        // -- an accept served from the listener's backlog does -- and blocking
        // on the loop with a completion already sitting in the queue stalls
        // for the whole timeout before anyone notices it.
        if drain-completions(s) then run-loop(s)
        else
          run-once(1000)
          if drain-completions(s) then run-loop(s)
          else
            if s.is-cancelling-now then s.wake-all-cancelled
            run-loop(s)

// Move every queued completion to the task waiting on it.  Returns True if
// anything was woken.
fun drain-completions( s : sched ) : io bool
  match next-completion()
    Nothing -> False
    Just(c) ->
      match s.unpark(c.request)
        Just(k) -> s.push-ready(fn() k(Completed(c)))
        Nothing -> ()          // nobody was waiting: the task was cancelled
      val _more = drain-completions(s)
      True

// Tear the group down: cancel everything and run until the tasks have
// unwound, so no task outlives the scope.
fun drain( s : sched ) : io ()
  s.set-cancelling
  s.wake-all-cancelled
  drain-until-quiet(s, 0)

fun drain-until-quiet( s : sched, rounds : int ) : io ()
  // A cancelled task only has to unwind, which needs no I/O, so a bounded
  // number of rounds is enough.  The bound stops a misbehaving task from
  // hanging shutdown.
  if rounds > 10000 then ()
  else match s.take-ready
    Just(t) -> { t(); drain-until-quiet(s, rounds + 1) }
    Nothing ->
      if s.waiting-count == 0 then ()
      else
        s.wake-all-cancelled
        match s.take-ready
          Just(t) -> { t(); drain-until-quiet(s, rounds + 1) }
          Nothing -> ()

// ----------------------------------------------------------------------------
// the operations tasks actually use
// ----------------------------------------------------------------------------

// Raised in a task that is cancelled.  Unwinds through `finally`, so every
// scoped resource is released.
//
// Cancellation is carried in the exception's *info*, not its message.
// `exception-info` is an open type, which is exactly the mechanism for this.
// Comparing the message meant any exception whose text happened to read
// "task cancelled" -- a handler reflecting a client-supplied string, say --
// was treated as a cancellation at six separate control-flow decisions, one
// of which decides whether a failing task takes the whole group down with it.
// A message is data; this is a decision, and it needs a constructor.
pub extend type exception-info
  ExnCancelled

pub val cancelled-message : string = "task cancelled"

pub fun throw-cancelled() : <async|io> a
  throw-exn(Exception(cancelled-message, ExnCancelled))

pub fun is-cancellation( ex : exception ) : bool
  match ex.info
    ExnCancelled -> True
    _            -> False

// Wait for a request, turning cancellation into an exception.
pub fun await( req : int ) : <async|io> completion
  match await-requests([req])
    Cancelled    -> throw-cancelled()
    Completed(c) -> c

// Run `action`, releasing `release(x)` when the *current task* ends.
//
// This is the async equivalent of `resource/scope`'s `with-resource`, and it
// exists because `finally` cannot span a suspension point in this runtime:
// when the scheduler's handler returns without resuming, Koka treats the
// computation as abandoned and runs `finally` handlers immediately -- which
// would close a socket at its first read.  Deferring to task exit is correct
// because a task ends exactly once, whether it returns, throws, or unwinds
// from cancellation.
//
// `finally` is still the right tool *within* a task for regions that do not
// suspend.
pub fun with-async-resource( acquire : () -> <async,io|e> a,
                             release : (a) -> io (),
                             action  : (a) -> <async,io|e> b ) : <async,io|e> b
  val r = acquire()
  defer({ release(r) })
  action(r)

// Start a task in the current group.
pub fun spawn( body : () -> <async|io> () ) : <async|io> ()
  spawn-task(body)

// Give other ready tasks a turn.  Also a cancellation check point.
pub fun yield() : <async|io> ()
  yield-now()
  if cancel-requested() then throw-cancelled()

// Sleep for `ms` milliseconds.  Cancellable.
//
// A cancelled sleep stops its timer on the way out.  Nothing is waiting on it
// any more, and a `sleep(30000)` that is cancelled after a millisecond would
// otherwise hold a `uv_timer_t` for the remaining thirty seconds.
pub fun sleep( ms : int ) : <async|io> ()
  val req = fresh-request()
  check-uv(arm-timer(req, ms), "cannot start a timer")
  match await-requests([req])
    Cancelled    -> { cancel-timer(req); throw-cancelled() }
    Completed(_) -> ()

// Wait for a request with a deadline: the request and a timer race, and
// whichever completes first wins.  `Nothing` means the deadline passed.
//
// This is the cancellable timeout that every socket operation uses.  It is a
// real race, not a poll: the task is parked on both ids at once and the
// scheduler resumes it with whichever arrives.
//
// Whichever way the race ends, the timer is stopped before returning.  The
// deadline usually *loses* -- the read completes long before it expires -- and
// a timer left armed then holds a libuv handle for the rest of its interval
// and fires a completion no task is parked on.  At `http/server`'s 30 s idle
// timeout, one read per request, that is a live handle per request for thirty
// seconds.  `cancel-timer` is a no-op on a timer that has already fired, so
// the arm where the deadline *won* costs nothing but says what it means.
pub fun await-within( req : int, ms : int ) : <async|io> maybe<completion>
  val timer = fresh-request()
  check-uv(arm-timer(timer, ms), "cannot start a timer")
  match await-requests([req, timer])
    Cancelled -> { cancel-timer(timer); throw-cancelled() }
    Completed(c) ->
      cancel-timer(timer)
      if c.request == req then Just(c) else Nothing
