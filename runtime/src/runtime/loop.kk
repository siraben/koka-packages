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
  // A new stream id (accept, connect) or an octet count (read).
  value   : int
  data    : bytes
  text    : string

pub fun is-ok( c : completion ) : bool
  c.status == 0

pub fun error-message( c : completion ) : string
  if c.status == 0 then "" else prim-strerror(c.status.int32)

// ----------------------------------------------------------------------------
// lifecycle
// ----------------------------------------------------------------------------

pub fun loop-init() : io ()
  val r = prim-init().int
  if r != 0 then throw("cannot start the event loop: " ++ prim-strerror(r.int32))

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

pub fun arm-accept( listener : int, request : int ) : io int
  prim-accept(listener.int64, request.int64).int

pub fun arm-read( stream : int, request : int, max : int ) : io int
  prim-read(stream.int64, request.int64, max.int64).int

pub fun arm-write( stream : int, request : int, data : bytes ) : io int
  prim-write(stream.int64, request.int64, data.unsafe-bytes-raw).int

pub fun arm-resolve( host : string, request : int ) : io int
  prim-resolve(host, request.int64).int

// ----------------------------------------------------------------------------
// streams
// ----------------------------------------------------------------------------

// Bind and listen.  Returns a stream id, or throws with the libuv message.
pub fun listen( host : string, port : int, backlog : int = 128 ) : io int
  val r = prim-listen(host, port.int32, backlog.int32).int
  if r < 0 then throw("cannot listen on " ++ host ++ ":" ++ port.show ++ ": " ++ prim-strerror(r.int32))
  r

// Start connecting.  Returns the stream id immediately; `request` completes
// when the connection is established or fails.
pub fun connect( host : string, port : int, request : int ) : io int
  val r = prim-connect(host, port.int32, request.int64).int
  if r < 0 then throw("cannot connect to " ++ host ++ ":" ++ port.show ++ ": " ++ prim-strerror(r.int32))
  r

// The port actually bound; useful when port 0 was requested.
pub fun bound-port( stream : int ) : io int
  prim-bound-port(stream.int64).int

pub fun peer-address( stream : int ) : io string
  prim-peer(stream.int64)

// Close a stream.  Idempotent.  Any pending read or accept on it is completed
// with a cancelled status, so no task is left waiting on a closed stream.
pub fun close-stream( stream : int ) : io ()
  prim-close(stream.int64)
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
extern prim-is-open( stream : int64 ) : io bool
  c "kk_uv_is_open"
extern prim-peer( stream : int64 ) : io string
  c "kk_uv_peer"
extern prim-resolve( host : string, request : int64 ) : io int32
  c "kk_uv_resolve"
extern prim-strerror( status : int32 ) : string
  c "kk_uv_strerror"
