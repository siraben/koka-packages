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
   waiting on a channel is woken and unwinds like any other.
*/
module runtime/channel

import runtime/loop
import runtime/task

pub struct channel<a>
  capacity : int
  // buffered items, oldest first
  items    : ref<global, list<a>>
  closed   : ref<global, bool>
  // request ids of tasks waiting to receive, and to send
  receivers : ref<global, list<int>>
  senders   : ref<global, list<int>>

// Create a channel with room for `capacity` items.  Capacity must be at least
// one; an unbounded channel is not offered.
pub fun channel( capacity : int = 16 ) : io channel<a>
  if capacity < 1 then throw("a channel needs a capacity of at least 1")
  Channel(capacity, ref([]), ref(False), ref([]), ref([]))

// Monomorphic accessors: reading a `ref` inline inside an `async` function
// leaves koka 3.2.7's inference with an undischargeable constraint.
fun buffered( c : channel<a> ) : io list<a>
  val i = c.items
  !i

fun set-buffered( c : channel<a>, xs : list<a> ) : io ()
  val i = c.items
  i := xs

fun is-closed( c : channel<a> ) : io bool
  val f = c.closed
  !f

fun take-waiter( r : ref<global, list<int>> ) : io maybe<int>
  match !r
    Nil -> Nothing
    Cons(x, rest) -> { r := rest; Just(x) }

fun add-waiter( r : ref<global, list<int>>, req : int ) : io ()
  r := (!r) ++ [req]

// Wake one waiter, if any, by completing a zero-delay timer on its request.
fun wake-one( r : ref<global, list<int>> ) : io ()
  match take-waiter(r)
    Nothing  -> ()
    Just(req) ->
      val rc = arm-timer(req, 0)
      if rc != 0 then throw("cannot wake a channel waiter: " ++ strerror(rc))

pub fun count( c : channel<a> ) : io int
  c.buffered.length

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
    val req = fresh-request()
    add-waiter(c.senders, req)
    await(req)
    c.send(x)
  else
    c.set-buffered(c.buffered ++ [x])
    wake-one(c.receivers)

// Receive the oldest item, waiting while the channel is empty.
//
// `Nothing` means the channel is closed *and* drained -- buffered items are
// always delivered first, so closing never loses anything.
pub fun receive( c : channel<a> ) : <async|io> maybe<a>
  match c.buffered
    Cons(x, rest) ->
      c.set-buffered(rest)
      wake-one(c.senders)
      Just(x)
    Nil ->
      if c.is-closed then Nothing
      else
        val req = fresh-request()
        add-waiter(c.receivers, req)
        await(req)
        c.receive

// Take an item if one is buffered, without waiting.
pub fun try-receive( c : channel<a> ) : io maybe<a>
  match c.buffered
    Nil -> Nothing
    Cons(x, rest) ->
      c.set-buffered(rest)
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
      val rc = arm-timer(req, 0)
      if rc != 0 then throw("cannot wake a channel waiter: " ++ strerror(rc))
      wake-all(r)
