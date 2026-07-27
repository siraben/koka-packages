/* A bounded channel.

   The minimum needed to connect socket reads, request parsing, response
   writing and task coordination -- not a streaming framework.

   ## Bounded, always

   There is no unbounded constructor.  `channel(capacity)` requires a positive
   capacity, and a `send` on a full channel *suspends the sending task* until a
   receiver takes something.  That is backpressure: a producer cannot outrun a
   consumer and grow a queue without limit.

   ## No silent loss

   A `send` either delivers the value or raises.  Closing a channel that still
   holds items does not discard them: receivers drain what is buffered and only
   then see the close.  A `send` to a closed channel raises rather than
   quietly dropping the value.

   ## Cancellation

   `send` and `receive` suspend through the task scheduler, so a cancelled task
   waiting on a channel is woken and unwinds like any other -- and takes its
   request id out of the waiter list on the way, so the next `wake-one` cannot
   spend the wake-up on a task that no longer exists.

   ## The buffer

   The buffer is two lists rather than one: `front` holds the items ready to
   come out, oldest first, and `back` holds what has been sent since, newest
   first.  `send` conses onto `back` and `receive` takes the head of `front`,
   reversing `back` into it when `front` runs out, so every item is moved at
   most once and both are amortised O(1).  A single list appended to with
   `items ++ [x]` is O(buffered) per send, which made a channel whose capacity
   actually fills quadratic in the number of hand-offs.
*/
module runtime/channel

import runtime/loop
import runtime/task

pub struct channel<a>
  capacity : int
  // buffered items ready to come out, oldest first
  front    : ref<global, list<a>>
  // buffered items sent since `front` was last refilled, newest first
  back     : ref<global, list<a>>
  // how many items the two lists hold between them, so `count` and `is-full`
  // are O(1) rather than a length scan on every send
  size     : ref<global, int>
  closed   : ref<global, bool>
  // request ids of tasks waiting to receive, and to send
  receivers : ref<global, list<int>>
  senders   : ref<global, list<int>>

// Create a channel with room for `capacity` items.  Capacity must be at least
// one; an unbounded channel is not offered.
pub fun channel( capacity : int = 16 ) : io channel<a>
  if capacity < 1 then throw("a channel needs a capacity of at least 1")
  Channel(capacity, ref([]), ref([]), ref(0), ref(False), ref([]), ref([]))

// Every helper that touches the channel's state is a named `io` function for
// the same reason: reading a `ref` inline inside an `async` function leaves
// koka 3.2.7's inference with an undischargeable constraint.
fun is-closed( c : channel<a> ) : io bool
  val f = c.closed
  !f

// Add one item to the back of the buffer.
fun push-item( c : channel<a>, x : a ) : io ()
  val b = c.back
  b := Cons(x, !b)
  val n = c.size
  n := !n + 1

// Take the oldest item, or `Nothing` when the buffer is empty.  Refilling
// `front` from the reversed `back` is what keeps this amortised O(1).
fun pop-item( c : channel<a> ) : io maybe<a>
  val f = c.front
  val n = c.size
  match !f
    Cons(x, rest) -> { f := rest; n := !n - 1; Just(x) }
    Nil ->
      val b = c.back
      match (!b).reverse
        Nil -> Nothing
        Cons(x, rest) -> { b := []; f := rest; n := !n - 1; Just(x) }

fun take-waiter( r : ref<global, list<int>> ) : io maybe<int>
  match !r
    Nil -> Nothing
    Cons(x, rest) -> { r := rest; Just(x) }

fun add-waiter( r : ref<global, list<int>>, req : int ) : io ()
  r := (!r) ++ [req]

// Take a request id back out of the waiter list.
//
// A `send` or `receive` that is cancelled while parked unwinds past the point
// where it would have been woken, and its id has to go with it.  Left behind,
// the id is handed out by the next `take-waiter`, a timer is armed on it, no
// task is parked on it and the wake-up is lost: two cancelled senders and a
// channel deadlocks with a free slot and a live receiver.
fun drop-waiter( r : ref<global, list<int>>, req : int ) : io ()
  r := (!r).filter(fn(i) i != req)

// Wake one waiter, if any, by completing a zero-delay timer on its request.
fun wake-one( r : ref<global, list<int>> ) : io ()
  match take-waiter(r)
    Nothing  -> ()
    Just(req) -> check-uv(arm-timer(req, 0), "cannot wake a channel waiter")

// Park on `req` until somebody wakes it, taking the id back out of `waiters`
// however that ends.  `finally` cannot be used here: it spans a suspension
// point, which in this runtime means it fires at the *first* park rather than
// at the end.  See `with-async-resource`.
fun park-on( waiters : ref<global, list<int>>, req : int ) : <async|io> ()
  add-waiter(waiters, req)
  val outcome = try({ await(req) })
  // Unconditional, because that is the invariant: the id belongs in the list
  // for exactly as long as this call is parked, and no longer.
  drop-waiter(waiters, req)
  match outcome
    Ok(_)     -> ()
    Error(ex) -> throw-exn(ex)

pub fun count( c : channel<a> ) : io int
  val n = c.size
  !n

pub fun is-full( c : channel<a> ) : io bool
  c.count >= c.capacity

// ----------------------------------------------------------------------------
// sending and receiving
// ----------------------------------------------------------------------------

// Send, waiting while the channel is full.  Raises if the channel is closed.
pub fun send( c : channel<a>, x : a ) : <async|io> ()
  if c.is-closed then throw("send on a closed channel")
  elif c.is-full then
    // Park until a receiver makes room, then try again.  The waiter is woken
    // by a zero-delay timer, which is how a purely in-process event reaches
    // the scheduler.
    park-on(c.senders, fresh-request())
    c.send(x)
  else
    c.push-item(x)
    wake-one(c.receivers)

// Receive the oldest item, waiting while the channel is empty.
//
// `Nothing` means the channel is closed *and* drained -- buffered items are
// always delivered first, so closing never loses anything.
pub fun receive( c : channel<a> ) : <async|io> maybe<a>
  match c.pop-item
    Just(x) ->
      wake-one(c.senders)
      Just(x)
    Nothing ->
      if c.is-closed then Nothing
      else
        park-on(c.receivers, fresh-request())
        c.receive

// Take an item if one is buffered, without waiting.
pub fun try-receive( c : channel<a> ) : io maybe<a>
  match c.pop-item
    Nothing -> Nothing
    Just(x) ->
      wake-one(c.senders)
      Just(x)

// Close the channel.  Buffered items remain available; every waiting task is
// woken so it can observe the close.
pub fun close( c : channel<a> ) : io ()
  val f = c.closed
  f := True
  wake-all(c.receivers)
  wake-all(c.senders)

fun wake-all( r : ref<global, list<int>> ) : io ()
  match take-waiter(r)
    Nothing -> ()
    Just(req) ->
      check-uv(arm-timer(req, 0), "cannot wake a channel waiter")
      wake-all(r)
