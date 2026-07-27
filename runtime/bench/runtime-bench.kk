/* What this measures, and why.

   The scheduler is on the path of every socket operation, so the numbers that
   matter are the per-operation costs of the three things a task does: yield to
   the scheduler, be spawned, and move a value through a channel.

   `sleep(0)` is measured separately from `yield` because it is a different
   mechanism -- it arms a libuv timer and parks on the completion, so it costs
   a trip through the event loop -- and the channel wake-up path is built on
   exactly that, which is why a channel hand-off cannot be as cheap as a yield.

   Everything runs inside one `with-task-group`, because starting a group also
   starts the loop, and a benchmark that paid for that per operation would be
   measuring `loop-init`.

   ## Nothing here busy-waits, and that is not a style preference

   `run-loop` drains libuv completions only when the ready queue is empty.  A
   task that waits for a sibling by looping on `yield` therefore keeps itself
   ready forever, the loop is never driven, and the sibling parked on a
   completion is never woken: the program livelocks rather than finishing
   slowly.  So the rows below wait by *parking* -- the root receives from the
   channel, and the spawn row lets the group's own drain run the children --
   which is also how a real task is supposed to wait.
*/
import kktest/bench
import runtime/loop
import runtime/task
import runtime/channel

fun yield-loop( n : int ) : <async|io> int
  fun go( i : int ) : <async|io> ()
    if i >= n then () else { yield(); go(i + 1) }
  go(0)
  n

fun sleep-loop( n : int ) : <async|io> int
  fun go( i : int ) : <async|io> ()
    if i >= n then () else { sleep(0); go(i + 1) }
  go(0)
  n

// `n` tasks that each bump a counter and end.  The root returns as soon as they
// are all spawned; the group's teardown runs whatever is still ready, so the
// counter is complete by the time `with-task-group` returns.
fun spawn-bench( n : int ) : io int
  val done = ref(0)
  with-task-group fn(_g)
    fun go( i : int ) : <async|io> ()
      if i >= n then () else { spawn(fn() done := !done + 1); go(i + 1) }
    go(0)
  !done

// One producer task and the root as consumer.  With a capacity of 16 the
// producer parks once the buffer fills, so most items cross a suspension point
// in each direction; with a capacity above `n` it never parks, which is what
// the second row isolates.
fun channel-bench( n : int, capacity : int ) : io int
  with-task-group fn(_g)
    val c : channel<int> = channel(capacity)
    spawn fn()
      fun send-all( i : int ) : <async|io> ()
        if i >= n then c.close else { c.send(i); send-all(i + 1) }
      send-all(0)
    fun recv( got : int ) : <async|io> int
      match c.receive
        Just(_)  -> recv(got + 1)
        Nothing  -> got
    recv(0)

fun in-group( body : () -> <async|io> int ) : io int
  with-task-group(fn(_g) body())

fun main()
  report("runtime", [
    measure("yield",                       200000, fn() in-group(fn() yield-loop(200000))),
    measure("yield",                       800000, fn() in-group(fn() yield-loop(800000))),
    measure("sleep(0) (arm timer + park)",  20000, fn() in-group(fn() sleep-loop(20000))),
    measure("sleep(0) (arm timer + park)",  80000, fn() in-group(fn() sleep-loop(80000))),
    measure("spawn a task that returns",     50000, fn() spawn-bench(50000)),
    measure("spawn a task that returns",    200000, fn() spawn-bench(200000)),
    // The two channel rows differ only in capacity: at 16 the buffer never
    // holds more than 16 items, and at 32k it holds everything that has been
    // sent.  This pair is here because it used to expose a quadratic append --
    // `items ++ [x]` per send, plus an `is-full` that measured the buffer with
    // `length` -- which made the wide row 310x the narrow one.  The buffer is
    // now a two-list queue with its size kept alongside, so the wide row is
    // the *cheap* one and the narrow row pays for parking the producer at
    // capacity.  Keep both: the pair is what would show the append coming back.
    measure("channel send+receive, cap 16",  20000, fn() channel-bench(20000, 16)),
    measure("channel send+receive, cap 32k", 20000, fn() channel-bench(20000, 32768)),
  ])
