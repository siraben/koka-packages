/* Small operating-system primitives the test framework needs and that
   `std/os` does not provide: process exit, monotonic time, watchdog timers,
   and temporary files.

   These are deliberately not exported as a general OS library; they exist so
   that a test run can report failure to `koka test`, bound its own runtime,
   and clean up after itself.
*/
module kktest/sys

import std/num/int32
import std/num/int64

extern import
  c file "sys-inline.c"

// Terminate the process immediately with `code`.
//
// `koka test` decides pass/fail from the exit status, and a Koka program
// otherwise always exits 0 -- even after an uncaught exception -- so a test
// runner has to say so explicitly.
pub fun exit( code : int ) : io a
  prim-exit(code.int32)
  // `exit` never returns, but the type checker cannot know that.
  throw("unreachable: exit returned")

extern prim-exit( code : int32 ) : io ()
  c "kk_test_exit"

// Milliseconds on a monotonic clock. Only differences are meaningful.
pub fun mono-ms() : io int
  prim-mono-ms().int
extern prim-mono-ms() : io int64
  c "kk_test_mono_ms"

// Arm a watchdog that kills the process after `seconds`, printing `msg`.
//
// This is a real alarm rather than a check-afterwards, so a test that hangs
// or loops forever is still bounded.  The cost is that it takes the whole
// test program with it; the message says which test was running so the
// failure is still diagnosable.  Passing 0 disarms it.
pub fun set-watchdog( seconds : int, msg : string ) : io ()
  prim-set-watchdog(seconds.int32, msg)
extern prim-set-watchdog( seconds : int32, msg : string ) : io ()
  c "kk_test_set_watchdog"

// Create a fresh directory under the system temporary directory.
// The caller is responsible for removing it; `with-temp-dir` does that.
pub fun make-temp-dir( pre : string = "kktest" ) : io string
  val d = prim-make-temp-dir(pre)
  if d.is-empty then throw("could not create a temporary directory")
  d
extern prim-make-temp-dir( pre : string ) : io string
  c "kk_test_make_temp_dir"

// Remove a directory tree.  Missing paths are not an error.
pub fun remove-tree( path : string ) : io ()
  prim-remove-tree(path)
extern prim-remove-tree( path : string ) : io ()
  c "kk_test_remove_tree"

// Does this path exist (as a file or a directory)?
pub fun path-exists( path : string ) : io bool
  prim-path-exists(path)
extern prim-path-exists( path : string ) : io bool
  c "kk_test_path_exists"
