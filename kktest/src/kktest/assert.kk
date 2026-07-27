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

// String assertions keep the needle and haystack in the failure report.  They
// are deliberately separate from collection membership: strings already have
// a stable, useful rendering and do not need an element `show` parameter.
pub fun assert-contains( actual : string, expected : string, msg : string = "" ) : exn ()
  if !actual.contains(expected) then
    assert-fail(label(msg) ++ "\n  expected substring: " ++ expected.show ++
                             "\n  actual:             " ++ actual.show)

pub fun assert-not-contains( actual : string, unexpected : string,
                             msg : string = "" ) : exn ()
  if actual.contains(unexpected) then
    assert-fail(label(msg) ++ "\n  unexpected substring: " ++ unexpected.show ++
                             "\n  actual:               " ++ actual.show)

// Extract a present value or fail.  This makes tests of APIs returning
// `maybe` concise without inventing a default value for the absent case.
pub fun assert-just( actual : maybe<a>, msg : string = "",
                     ?show : a -> string ) : exn a
  match actual
    Just(x) -> x
    Nothing -> assert-fail(label(msg) ++ "\n  expected: Just(_)\n  actual:   Nothing")

pub fun assert-nothing( actual : maybe<a>, msg : string = "",
                        ?show : a -> string ) : exn ()
  match actual
    Nothing -> ()
    Just(x) -> assert-fail(label(msg) ++ "\n  expected: Nothing\n  actual:   Just(" ++ x.show ++ ")")

pub fun assert-less( actual : a, upper : a, msg : string = "",
                     ?(<) : (a,a) -> bool, ?show : a -> string ) : exn ()
  if !(actual < upper) then
    assert-fail(label(msg) ++ "\n  expected: " ++ actual.show ++ " < " ++ upper.show)

pub fun assert-at-most( actual : a, upper : a, msg : string = "",
                        ?(<) : (a,a) -> bool, ?(==) : (a,a) -> bool,
                        ?show : a -> string ) : exn ()
  if !(actual < upper || actual == upper) then
    assert-fail(label(msg) ++ "\n  expected: " ++ actual.show ++ " <= " ++ upper.show)

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
