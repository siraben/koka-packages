/* Structured logging, as an effect.

   The application-facing API is an effect, so a request handler says *what*
   happened and the handler installed at the edge decides where it goes and
   what context it carries.  That is what makes a request id automatic: the
   server installs a handler that adds it, and no handler function has to
   thread it through.

   Records are rendered as line-delimited JSON; where they go is the `emit`
   parameter's business, not this module's.  Nothing here writes to a stream
   by itself.  The one default in this tree is `http/server`'s
   `default-log-config`, which writes to **stdout**.  There is no distributed
   tracing and no metrics; that is out of scope.

   ## Determinism

   Fields are emitted in the order given, with the handler's own fields first.
   The timestamp is the only non-deterministic part, and `with-json-logger`
   takes the clock as a parameter so a test can pin it and assert on whole
   lines.
*/
module logging/log

import strbuilder/strbuilder

pub type level
  Debug
  Info
  Warn
  Error

pub fun show( l : level ) : string
  match l
    Debug -> "debug"
    Info  -> "info"
    Warn  -> "warn"
    Error -> "error"

pub fun severity( l : level ) : int
  match l
    Debug -> 10
    Info  -> 20
    Warn  -> 30
    Error -> 40

// A contextual field.  Values are strings: a log line is text, and forcing the
// caller to render means no surprise formatting at the edge.
pub alias field = (string, string)

pub fun int/field( name : string, v : int ) : field
  (name, v.show)

pub fun bool/field( name : string, v : bool ) : field
  (name, if v then "true" else "false")

// The logging effect.  `log` is the only operation; everything else is sugar.
//
// Not `linear`, though both operations are tail-resumptive: a `linear` effect
// requires its handlers to use only linear effects, and every handler here
// emits through `io`, which contains `exn`.  The compiler rejects it with
// "handler for logger needs to be linear but uses a non-linear effect: exn".
pub effect logger
  fun log-record( lvl : level, message : string, fields : list<field> ) : ()
  // Fields that every record from here on carries.
  fun log-base-fields() : list<field>

pub fun log( lvl : level, message : string, fields : list<field> = [] ) : <logger|e> ()
  log-record(lvl, message, fields)

pub fun debug( message : string, fields : list<field> = [] ) : <logger|e> ()
  log-record(Debug, message, fields)

pub fun info( message : string, fields : list<field> = [] ) : <logger|e> ()
  log-record(Info, message, fields)

pub fun warn( message : string, fields : list<field> = [] ) : <logger|e> ()
  log-record(Warn, message, fields)

pub fun error( message : string, fields : list<field> = [] ) : <logger|e> ()
  log-record(Error, message, fields)

// ----------------------------------------------------------------------------
// handlers
// ----------------------------------------------------------------------------

// Emit line-delimited JSON through `emit`, dropping anything below `min`.
//
// `emit` takes the finished line so the caller decides the destination:
// stderr for a service, a collector for a test.
pub fun with-json-logger( emit : (string) -> <io|e> (),
                          action : () -> <logger,io|e> a,
                          min : level = Info,
                          base-fields : list<field> = [],
                          now : () -> <io|e> int = default-clock ) : <io|e> a
  with handler
    fun log-base-fields() base-fields
    fun log-record(lvl, message, fields)
      if lvl.severity >= min.severity then
        emit(render(lvl, message, base-fields ++ fields, now()))
  action()

// Add fields to every record produced by `action`.
//
// Nesting is what a server uses: the outer handler holds the service name, the
// per-connection handler adds the request id.
pub fun with-context( extra : list<field>, action : () -> <logger|e> a ) : <logger|e> a
  val outer = log-base-fields()
  with override
    fun log-base-fields() outer ++ extra
    fun log-record(lvl, message, fields) log-record(lvl, message, extra ++ fields)
  action()

// Discard everything.  For tests that exercise a code path without caring
// about its output.
pub fun with-no-logger( action : () -> <logger|e> a ) : e a
  with handler
    fun log-base-fields() []
    fun log-record(_lvl, _message, _fields) ()
  action()

// ----------------------------------------------------------------------------
// rendering
// ----------------------------------------------------------------------------

// One JSON object on one line: level, message, timestamp, then the fields in
// order.  Keys are never reordered, so output is diffable.
pub fun render( lvl : level, message : string, fields : list<field>, at : int ) : div string
  build(fn(b) render-into(b, lvl, message, fields, at))

fun render-into( b : strbuilder, lvl : level, message : string,
                 fields : list<field>, at : int ) : div strbuilder
  val head = b.append("{\"level\":").append-json-string(lvl.show)
              .append(",\"ts\":").append-int(at)
              .append(",\"msg\":").append-json-string(message)
  fields.foldl(head, add-field).append("}")

fun add-field( acc : strbuilder, f : field ) : div strbuilder
  acc.append(",").append-json-string(f.fst).append(":").append-json-string(f.snd)

// Milliseconds since the epoch.
pub fun default-clock() : <io|e> int
  prim-now-ms()

extern import
  c file "clock-inline.c"

extern prim-now-ms() : <io|e> int
  c "kk_log_now_ms"
