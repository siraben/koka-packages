/* Scoped resource management: one abstraction for acquire / use / release.

   Every native resource in this program -- files, sockets, database
   connections, prepared statements, timers -- is released through this module,
   so there is exactly one place where release ordering and failure handling
   are decided.

   ## Guarantees

   Release runs exactly once, and it runs on every exit path:

   | exit path                                     | released |
   | --------------------------------------------- | -------- |
   | normal return                                 | yes      |
   | exception                                     | yes      |
   | an outer handler discarding the continuation  | yes      |
   | partial initialisation inside a scope         | yes, for what was acquired |
   | nested scopes                                 | inner first, then outer |

   The mechanism is `finally`, whose handler is `final ctl`: it runs when the
   computation ends *for any reason*, including a handler that never resumes.

   ## The one place this does not hold: inside a task

   `finally` cannot span a suspension point.  When `runtime/task`'s scheduler
   captures a continuation and returns without resuming it, Koka treats that
   computation as ended and runs the `final ctl` **there** -- and then runs it
   a second time when the task really unwinds.  So a `with-resource` wrapped
   around anything that awaits releases early *and* releases twice:

   ```
   acquire, release, <the task is still running>, ..., release
   ```

   For a socket or a prepared statement that is a use-after-close followed by
   a double-close.  It is not a bug this module can fix: making the release
   idempotent would need mutable state, which would fix the effect row to `io`
   and defeat the polymorphism the next section describes.

   **Inside a task, use `runtime/task`'s `defer` or `with-async-resource`.**
   Those register the release with the task itself, so it runs once, when the
   task ends -- including when it ends by cancellation.  `with-resource` is
   for code that never suspends: the database connections and statements in
   the reference service, which the single-threaded loop guarantees are used
   by one task at a time.

   The `:owned` handles below are idempotent (see "Double release" at the end)
   and are the safe choice if a resource must outlive a lexical scope.

   ## Effect polymorphism

   `with-resource` and `with-scope` are polymorphic in the effect row and never
   discharge an effect they then re-raise.  That matters: Koka only subsumes
   closed rows, so an implementation written in terms of `try` would work only
   at one fixed effect and could not sit under the cancellation handler that
   Milestone 4 introduces.

   ## Release ordering and failure

   Within one scope, resources are released in reverse acquisition order, so a
   statement is finalised before the connection it belongs to is closed.

   Releases are nested inside each other with `finally`, so **every** release
   runs even if an earlier one throws.  If a release does throw while the stack
   is already unwinding from another failure, the release's exception is the
   one the caller sees -- the same rule as `finally` in most languages.  Keep
   release actions failure-free where the original error matters; the native
   wrappers in this program do (they ignore close errors on resources that are
   already broken).

   ## Double release and use after release

   An `:owned` carries a released flag.  `release-owned` is idempotent.
   `with-value` and `get` on a released handle throw rather than handing the
   caller a resource the operating system may already have reused.
*/
module resource/scope

// ----------------------------------------------------------------------------
// the core combinator
// ----------------------------------------------------------------------------

// Acquire, run `action` with the resource, and release afterwards -- on
// success, on failure, and on cancellation.
//
// This is the primitive; everything else here is built from it.
pub fun with-resource( acquire : () -> e a,
                       release : (a) -> e (),
                       action  : (a) -> e b ) : e b
  val r = acquire()
  finally({ release(r) }, { action(r) })

// ----------------------------------------------------------------------------
// owned handles
//
// Fixed to `io` because the released flag is a mutable reference.  Use these
// when a resource must be releasable *early*; otherwise `with-resource` is
// simpler and works at any effect.
// ----------------------------------------------------------------------------

pub struct owned<a>
  value          : a
  release-action : (a) -> io ()
  released       : ref<global, bool>

pub fun with-owned( acquire : () -> io a,
                    release : (a) -> io (),
                    action  : (owned<a>) -> io b ) : io b
  val r = acquire()
  val h = Owned(r, release, ref(False))
  finally({ release-owned(h) }, { action(h) })

pub fun is-released( h : owned<a> ) : io bool
  !h.released

// Release now.  Releasing an already-released handle does nothing, so an
// explicit early release followed by scope exit is safe.
pub fun release-owned( h : owned<a> ) : io ()
  // bind the ref first: `h.released := x` would parse as a record update
  val flag = h.released
  if !(!flag) then
    flag := True
    (h.release-action)(h.value)

// Use the resource.  Throws if it has already been released.
pub fun with-value( h : owned<a>, action : (a) -> io b ) : io b
  if !h.released
    then throw("use after release")
    else action(h.value)

// The resource itself, for callers that have already checked.
pub fun get( h : owned<a> ) : io a
  if !h.released then throw("use after release") else h.value

// ----------------------------------------------------------------------------
// scopes holding several resources
// ----------------------------------------------------------------------------

// A scope collects resources acquired during `action` and releases them all
// on exit, in reverse acquisition order.
//
// Use this when the number of resources is not known up front -- a request
// that opens a statement per query, for example.  When it *is* known, nested
// `with-resource` reads better.
pub struct scope
  entries : ref<global, list<() -> io ()>>

// Run `action` in a fresh scope.
pub fun with-scope( action : (scope) -> io a ) : io a
  val s = Scope(ref([]))
  finally({ release-all(s) }, { action(s) })

// Acquire inside a scope; the resource is released when the scope exits.
pub fun acquire( s : scope, get-it : () -> io a, release : (a) -> io () ) : io a
  val r  = get-it()
  val es = s.entries
  es := Cons({ release(r) }, !es)
  r

// Register an action to run when the scope exits, without acquiring anything.
pub fun on-exit( s : scope, action : () -> io () ) : io ()
  val es = s.entries
  es := Cons(action, !es)

// Release everything, newest first.
//
// Each release is nested inside the next with `finally`, so one that throws
// still leaves the remaining releases to run.  Leaking the rest would be worse
// than losing an error message.
fun release-all( s : scope ) : io ()
  val es = s.entries
  val actions = !es
  es := []
  run-all(actions)

fun run-all( actions : list<() -> io ()> ) : io ()
  match actions
    Nil           -> ()
    Cons(a, rest) -> finally({ run-all(rest) }, a)
