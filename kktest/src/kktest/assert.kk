/* Assertions.

   Every assertion reports failure by throwing, which the runner catches and
   turns into one failed test.  Messages always show what was expected and what
   was actually seen, because a failure that does not say that costs more time
   than it saves.

   A note on effects: assertions that only throw are effect polymorphic and
   usable anywhere.  Assertions that *run* an action (`assert-throws`,
   `assert-ok`) are fixed to `io`.  Koka only subsumes closed effect rows, so a
   function that discharges `exn` with `try` and then throws again cannot be
   written with a polymorphic tail `<exn|e>`; `io` already contains `exn`, so
   fixing the row is what makes those helpers expressible at all.  Test bodies
   run in `io`, so this costs nothing in practice.
*/
module kktest/assert

// Failures are marked so the runner can tell a failed check from a crash.
pub val assert-marker : string = "assertion failed: "

pub fun assert-fail( msg : string ) : exn a
  throw(assert-marker ++ msg)

// Was this exception a failed assertion rather than an unexpected error?
pub fun is-assertion( e : exception ) : bool
  e.message.starts-with(assert-marker).bool

pub fun assert-true( cond : bool, msg : string = "expected True" ) : exn ()
  if !cond then assert-fail(msg)

pub fun assert-false( cond : bool, msg : string = "expected False" ) : exn ()
  if cond then assert-fail(msg)

pub fun assert-equal( actual : a, expected : a, msg : string = "",
                      ?(==) : (a,a) -> bool, ?show : a -> string ) : exn ()
  if actual != expected then
    assert-fail(label(msg) ++ "\n  expected: " ++ expected.show ++
                             "\n  actual:   " ++ actual.show)

pub fun assert-not-equal( actual : a, unexpected : a, msg : string = "",
                          ?(==) : (a,a) -> bool, ?show : a -> string ) : exn ()
  if actual == unexpected then
    assert-fail(label(msg) ++ "\n  expected anything but: " ++ unexpected.show)

// Assert that `action` throws.  When `containing` is given the message must
// contain it, so a test cannot pass on the wrong error.
pub fun assert-throws( action : () -> io a, containing : string = "",
                       msg : string = "expected an exception" ) : io ()
  match try(action)
    Error(ex) ->
      if containing.is-notempty && !ex.message.contains(containing) then
        assert-fail(label(msg) ++ "\n  expected message containing: " ++ containing.show ++
                                 "\n  actual message:              " ++ ex.message.show)
    Ok(_) -> assert-fail(label(msg))

// Assert that `action` does not throw, reporting the exception if it does.
pub fun assert-ok( action : () -> io a, msg : string = "" ) : io a
  match try(action)
    Error(ex) -> assert-fail(label(msg) ++ "\n  unexpected exception: " ++ ex.message)
    Ok(x)     -> x

fun label( msg : string ) : string
  if msg.is-empty then "values differ" else msg
