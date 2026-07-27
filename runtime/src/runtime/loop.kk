/* The event loop, kept internal.

   This module is the only place that touches libuv.  It exposes request ids
   and completions; no raw native handle ever leaves it.  Everything above --
   tasks, timers, sockets -- is written against `arm-*` plus `next-completion`.

   There is exactly one loop and it is single threaded.  libuv callbacks never
   call into Koka: they append to a completion queue that `next-completion`
   drains.  See `uv-inline.c` for why.
*/
module runtime/loop

import std/num/int32
import std/num/int64
import bytes/bytes

extern import
  c file "uv-inline.c"

// A completion: which request finished, whether it succeeded, and what it
// produced.
pub struct completion
  request : int
  // 0 on success, a negative libuv error code otherwise.
  status  : int
  // The one number the operation produced, if it produced one: a new stream id
  // for an accept, and the octet count for a read (which is also `data.length`,
  // so nothing here reads it).  Which of the two it is follows from which
  // `arm-*` created the request, and the task that armed it is the only one
  // that ever sees the completion -- so the caller already knows, and tagging
  // it would only add a branch at each use site that no input can reach.
  value   : int
  data    : bytes
  text    : string

// Why a request failed.  Kept as a value rather than folded into a message:
// the numeric status is what tells a cancellation apart from ECONNRESET, and a
// caller that has only prose has to match on substrings to recover it.
pub struct uv-error
  // a negative libuv error code
  status  : int
  message : string

// Pair a libuv status with its message.  Every failure in this module is built
// through here, so no caller has to remember to look the text up.
pub fun uv-error-of( status : int ) : uv-error
  Uv-error(status, prim-strerror(status.int32))

// The failure a completion carries, or `Nothing` when it succeeded.
//
// `Nothing` rather than an empty message: the earlier `error-message` returned
// `""` for success, which is the same string a failure with no message would
// produce, so "it worked" and "it failed, silently" were indistinguishable.
pub fun error( c : completion ) : maybe<uv-error>
  if c.status == 0 then Nothing else Just(uv-error-of(c.status))

// Raised when a libuv operation fails.  The status travels in the exception's
// *info*, where a handler can match on it, rather than only inside the message.
//
// Folding it into the message meant a caller who needed to tell a cancellation
// from an ECONNRESET had to match on substrings of prose that was assembled
// for a human.  `exception-info` is an open type, which is the mechanism for
// exactly this -- the same reason `ExnCancelled` exists in `runtime/task`.
pub extend type exception-info
  ExnUv( status : int )

// The message is `what ++ ": " ++ the libuv text`, which is what every call
// site here spelled out by hand before.
pub fun throw-uv( what : string, e : uv-error ) : exn a
  throw-exn(Exception(what ++ ": " ++ e.message, ExnUv(e.status)))

// The common shape: a non-zero return from an `arm-*` or a setup call.
pub fun check-uv( status : int, what : string ) : exn ()
  if status != 0 then throw-uv(what, uv-error-of(status))

// ----------------------------------------------------------------------------
// lifecycle
// ----------------------------------------------------------------------------

pub fun loop-init() : io ()
  check-uv(prim-init().int, "cannot start the event loop")

// Close every handle and shut the loop down.  Safe to call more than once.
pub fun loop-shutdown() : io ()
  prim-shutdown()
  ()

// Fresh request id.  Ids are never reused within a process.
pub fun fresh-request() : io int
  prim-next-id().int

// Milliseconds on the loop's clock.  Only differences are meaningful.
pub fun now-ms() : io int
  prim-now().int

// ----------------------------------------------------------------------------
// driving
// ----------------------------------------------------------------------------

// Run the loop once.  Negative blocks until something happens, 0 polls, and a
// positive value blocks at most that many milliseconds.  Returns the number of
// live streams, so a caller can tell when nothing is left to wait for.
pub fun run-once( timeout-ms : int = -1 ) : io int
  prim-run-once(timeout-ms.int32).int

// How many completions are queued.
pub fun pending() : io int
  prim-pending().int

// How many timers are armed and have not fired yet.  Exposed for the same
// reason as `pending`: it is the only way to assert that a deadline which lost
// its race was actually stopped, rather than to assume it.
pub fun live-timers() : io int
  prim-live-timers().int

// Take the next completion, or `Nothing` when the queue is empty.
pub fun next-completion() : io maybe<completion>
  val id = prim-next-completion().int
  if id == 0 then Nothing
  else Just(Completion(id, prim-last-status().int, prim-last-value().int,
                       unsafe-bytes-from-raw(prim-last-bytes()), prim-last-text()))

// ----------------------------------------------------------------------------
// arming operations
//
// Each returns 0 on success or a negative libuv error.  The named request
// completes later, exactly once.
// ----------------------------------------------------------------------------

pub fun arm-timer( request : int, ms : int ) : io int
  prim-timer-start(request.int64, ms.int64).int

// Stop a timer that has not fired, so it neither holds a handle open nor
// completes a request nobody is waiting on any more.
//
// The deadline in a race normally *loses*: `await-within` returns as soon as
// the operation completes, and without this the timer stayed armed for the
// rest of its interval.  At `http/server`'s 30 s idle timeout that is one live
// `uv_timer_t` per socket read for thirty seconds, each of which then fires a
// completion that is drained and discarded.
//
// Safe when the timer has already fired or never existed: request ids are
// never reused, so this cannot stop somebody else's timer.
pub fun cancel-timer( request : int ) : io ()
  prim-timer-stop(request.int64)
  ()

pub fun arm-accept( listener : int, request : int ) : io int
  prim-accept(listener.int64, request.int64).int

pub fun arm-read( stream : int, request : int, max : int ) : io int
  prim-read(stream.int64, request.int64, max.int64).int

pub fun arm-write( stream : int, request : int, data : bytes ) : io int
  prim-write(stream.int64, request.int64, data.unsafe-bytes-raw).int

pub fun arm-resolve( host : string, request : int ) : io int
  prim-resolve(host, request.int64).int

// Abandon a pending accept or read on a stream.
//
// A deadline that expires stops the *task* waiting, but the operation is still
// armed here; without clearing it the next arm on the same stream fails with
// EBUSY.  Both are safe to call when nothing is armed.
pub fun cancel-accept( listener : int ) : io ()
  prim-cancel-accept(listener.int64)
  ()

pub fun cancel-read( stream : int ) : io ()
  prim-cancel-read(stream.int64)
  ()

// ----------------------------------------------------------------------------
// streams
// ----------------------------------------------------------------------------

// Bind and listen.  Returns a stream id, or throws with the libuv message.
pub fun listen( host : string, port : int, backlog : int = 128 ) : io int
  val r = prim-listen(host, port.int32, backlog.int32).int
  if r < 0 then throw-uv("cannot listen on " ++ host ++ ":" ++ port.show, uv-error-of(r))
  r

// Start connecting.  Returns the stream id immediately; `request` completes
// when the connection is established or fails.
pub fun connect( host : string, port : int, request : int ) : io int
  val r = prim-connect(host, port.int32, request.int64).int
  if r < 0 then throw-uv("cannot connect to " ++ host ++ ":" ++ port.show, uv-error-of(r))
  r

// The port actually bound; useful when port 0 was requested.
//
// `Left` when there is no such stream, when `getsockname` fails, or when the
// socket is not IPv4.  A single `-1` collapsed those three conditions into a
// number a caller then went on to print as a port; the error says which.
pub fun bound-port( stream : int ) : io either<uv-error, int>
  val r = prim-bound-port(stream.int64).int
  if r < 0 then Left(uv-error-of(r)) else Right(r)

pub fun peer-address( stream : int ) : io string
  prim-peer(stream.int64)

// Close a stream.  Idempotent.  Any pending read or accept on it is completed
// with a cancelled status, so no task is left waiting on a closed stream.
pub fun close-stream( stream : int ) : io ()
  prim-close(stream.int64)
  ()

// Close a *listening* socket.  Separate from `close-stream` so that a
// connected socket can never close the listener: the two are different kinds
// of handle and the C side refuses a mismatch.
pub fun close-listener( stream : int ) : io ()
  prim-close-listener(stream.int64)
  ()

pub fun is-open( stream : int ) : io bool
  prim-is-open(stream.int64)

pub fun strerror( status : int ) : string
  prim-strerror(status.int32)

// ----------------------------------------------------------------------------
// primitives
// ----------------------------------------------------------------------------

extern prim-init() : io int32
  c "kk_uv_init"
extern prim-shutdown() : io int32
  c "kk_uv_shutdown"
extern prim-run-once( timeout : int32 ) : io int32
  c "kk_uv_run_once"
extern prim-pending() : io int32
  c "kk_uv_pending"
extern prim-next-completion() : io int64
  c "kk_uv_next_completion"
extern prim-last-status() : io int32
  c "kk_uv_last_status"
extern prim-last-value() : io int64
  c "kk_uv_last_value"
extern prim-last-bytes() : io any
  c "kk_uv_last_bytes"
extern prim-last-text() : io string
  c "kk_uv_last_text"
extern prim-next-id() : io int64
  c "kk_uv_next_id"
extern prim-now() : io int64
  c "kk_uv_now"
extern prim-timer-start( request : int64, ms : int64 ) : io int32
  c "kk_uv_timer_start"
extern prim-timer-stop( request : int64 ) : io ()
  c "kk_uv_timer_stop"
extern prim-live-timers() : io int32
  c "kk_uv_live_timers"
extern prim-listen( host : string, port : int32, backlog : int32 ) : io int64
  c "kk_uv_listen"
extern prim-bound-port( stream : int64 ) : io int32
  c "kk_uv_bound_port"
extern prim-accept( listener : int64, request : int64 ) : io int32
  c "kk_uv_accept"
extern prim-connect( host : string, port : int32, request : int64 ) : io int64
  c "kk_uv_connect"
extern prim-read( stream : int64, request : int64, max : int64 ) : io int32
  c "kk_uv_read"
extern prim-write( stream : int64, request : int64, data : any ) : io int32
  c "kk_uv_write"
extern prim-close( stream : int64 ) : io ()
  c "kk_uv_close"
extern prim-close-listener( stream : int64 ) : io ()
  c "kk_uv_close_listener"
extern prim-is-open( stream : int64 ) : io bool
  c "kk_uv_is_open"
extern prim-peer( stream : int64 ) : io string
  c "kk_uv_peer"
extern prim-resolve( host : string, request : int64 ) : io int32
  c "kk_uv_resolve"
extern prim-cancel-accept( listener : int64 ) : io ()
  c "kk_uv_cancel_accept"
extern prim-cancel-read( stream : int64 ) : io ()
  c "kk_uv_cancel_read"
extern prim-strerror( status : int32 ) : string
  c "kk_uv_strerror"
