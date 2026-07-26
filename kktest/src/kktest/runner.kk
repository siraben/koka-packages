/* Test cases, groups, and the runner.

   A test program is an ordinary Koka executable whose `main` calls
   `run-tests`.  `koka test` compiles every `.kk` file under the project's test
   directories and runs it, so discovery at the file level is the project
   tool's job; this module only deals with what is inside one file.

   Output is deterministic: cases run in the order given, one line each, with
   no timestamps or durations.  That makes it diffable.
*/
module kktest/runner

import kktest/assert
import kktest/sys

// A single test.
pub struct test-case
  name        : string
  // A test marked `expect-fail` passes only if its body throws.  Use it for
  // known-broken behaviour that should not be silently forgotten.
  expect-fail : bool
  // Seconds after which the test program is killed.  A watchdog rather than a
  // check afterwards, so a hang is still bounded.  0 disables it.
  timeout-s   : int
  action      : () -> io ()

// A suite is a tree so that groups nest and compose in one list literal.
pub type suite
  Case( case : test-case )
  Group( name : string, items : list<suite> )

pub fun test( name : string, action : () -> io (),
              expect-fail : bool = False, timeout-s : int = 60 ) : suite
  Case(Test-case(name, expect-fail, timeout-s, action))

pub fun group( name : string, items : list<suite> ) : suite
  Group(name, items)

// Flatten to a list of (path, case) in source order.
pub fun flatten( items : list<suite>, path : string = "" ) : div list<test-case>
  items.flatmap fn(s)
    match s
      Case(c)      -> [c(name = join-path(path, c.name))]
      Group(g,sub) -> flatten(sub, join-path(path, g))

fun join-path( a : string, b : string ) : string
  if a.is-empty then b else a ++ "/" ++ b

// Run the suite and exit: 0 if everything passed, 1 otherwise.
//
// Exiting explicitly matters: a Koka program returns 0 even after an uncaught
// exception, so a runner that just fell off the end would report failure as
// success.
pub fun run-tests( items : list<suite> ) : io a
  val cases   = flatten(items)
  val results = cases.map(run-one)
  val failed  = results.filter(fn(r) !r.snd)
  println("")
  println(results.length.show ++ " tests, " ++
          (results.length - failed.length).show ++ " passed, " ++
          failed.length.show ++ " failed")
  failed.foreach( fn(r) println("  failed: " ++ r.fst) )
  exit(if failed.is-nil then 0 else 1)

fun run-one( c : test-case ) : io (string, bool)
  set-watchdog(c.timeout-s, "TIMEOUT after " ++ c.timeout-s.show ++
                            "s in test: " ++ c.name)
  val outcome = try({ (c.action)() })
  set-watchdog(0, "")
  match outcome
    Ok(_) ->
      if c.expect-fail then
        println("FAIL " ++ c.name)
        println("  expected this test to fail, but it passed")
        (c.name, False)
      else
        println("ok   " ++ c.name)
        (c.name, True)
    Error(ex) ->
      if c.expect-fail then
        println("ok   " ++ c.name ++ " (expected failure)")
        (c.name, True)
      else
        val kind = if ex.is-assertion then "" else " (unexpected exception)"
        println("FAIL " ++ c.name ++ kind)
        println("  " ++ indent(ex.message))
        (c.name, False)

fun indent( s : string ) : string
  s.split("\n").intersperse("\n  ").join
