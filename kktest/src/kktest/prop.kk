/* Property testing with shrinking.

   A `gen<a>` produces a value from a generator state and a "size" budget, and
   knows how to shrink a value towards simpler ones.  Shrinking is what makes
   a property failure readable: the raw counterexample from a random run is
   usually noise, and the shrunk one is usually the bug.

   Scope: enough for the packages in this program.  There is no coverage
   tracking, no generator combinator zoo, and no stateful-model testing.
*/
module kktest/prop

import kktest/assert
import kktest/random

// A generator: build a value, and offer simpler candidates for shrinking.
//
// `shrink` returns candidates ordered simplest-first.  It must be finite and
// must never return the value it was given, or shrinking will not terminate.
pub struct gen<a>
  // `div` because generators for recursive structures (lists, strings) loop
  // over a generated length that the type checker cannot bound.
  generate : (rng, int) -> div (rng, a)
  shrink   : (a) -> list<a>
  display  : (a) -> string

// ----------------------------------------------------------------------------
// Core generators
// ----------------------------------------------------------------------------

// Integers in `[-size, size]`, shrinking towards zero.
pub fun gen-int( lo : int = -1000000, hi : int = 1000000 ) : gen<int>
  Gen( fn(r, size)
         val bound = if size <= 0 then 0 else size
         r.next-range(max(lo, 0 - bound), min(hi, bound))
     , shrink-int
     , fn(i) i.show )

fun shrink-int( i : int ) : list<int>
  if i == 0 then []
  else
    val halved = i / 2
    val cands  = [0, halved, i - (if i > 0 then 1 else -1)]
    cands.filter(fn(c) c != i).distinct-ints

// Non-negative integers, shrinking towards zero.
pub fun gen-nat( hi : int = 1000000 ) : gen<int>
  Gen( fn(r, size) r.next-range(0, min(hi, max(size, 0)))
     , fn(i) shrink-int(i).filter(fn(c) c >= 0)
     , fn(i) i.show )

pub fun gen-bool() : gen<bool>
  Gen( fn(r, _size) r.next-bool
     , fn(b) if b then [False] else []
     , fn(b) b.show )

// Printable ASCII strings up to `size` characters, shrinking by dropping
// characters and then by simplifying them towards 'a'.
pub fun gen-string( alphabet : string = "abcdefghijklmnopqrstuvwxyz0123456789 " ) : gen<string>
  val chars = alphabet.list
  Gen( fn(r, size)
         val (r1, n) = r.next-range(0, max(size, 0))
         gen-chars(r1, n, chars, [])
     , shrink-string
     , fn(s) s.show )

fun gen-chars( r : rng, n : int, chars : list<char>, acc : list<char> ) : div (rng, string)
  if n <= 0 then (r, acc.reverse.string)
  else
    val (r1, i) = r.next-below(chars.length)
    match chars.drop(i)
      Cons(c,_) -> gen-chars(r1, n - 1, chars, Cons(c, acc))
      Nil       -> (r1, acc.reverse.string)

fun shrink-string( s : string ) : list<string>
  val cs = s.list
  if cs.is-nil then []
  else
    // drop the second half, drop one character from the front and the back
    val n = cs.length
    val cands = [ "", cs.take(n / 2).string, cs.drop(1).string, cs.take(n - 1).string ]
    cands.filter(fn(c) c != s).distinct-strings

// Lists of up to `size` elements, shrinking by dropping elements first (which
// finds "any element triggers it" fast) and then by shrinking elements.
pub fun gen-list( elem : gen<a> ) : gen<list<a>>
  Gen( fn(r, size)
         val (r1, n) = r.next-range(0, max(size, 0))
         gen-elems(elem, r1, n, [])
     , fn(xs) shrink-list(elem, xs)
     , fn(xs) "[" ++ xs.map(elem.display).join(",") ++ "]" )

fun gen-elems( elem : gen<a>, r : rng, n : int, acc : list<a> ) : div (rng, list<a>)
  if n <= 0 then (r, acc.reverse)
  else
    val (r1, x) = (elem.generate)(r, 100)
    gen-elems(elem, r1, n - 1, Cons(x, acc))

fun shrink-list( elem : gen<a>, xs : list<a> ) : list<list<a>>
  if xs.is-nil then []
  else
    val n = xs.length
    val drops = [ [], xs.take(n / 2), xs.drop(1), xs.take(n - 1) ]
    // shrink the first element, keeping the rest: enough in practice and it
    // keeps the candidate set small
    val heads = match xs
                  Cons(h, t) -> (elem.shrink)(h).map(fn(h2) Cons(h2, t))
                  Nil        -> []
    // every drop is strictly shorter (xs is non-empty here) and every head
    // candidate has a strictly simpler first element, so no candidate can
    // equal `xs` and shrinking always makes progress
    drops ++ heads

// Pairs.
pub fun gen-pair( ga : gen<a>, gb : gen<b> ) : gen<(a, b)>
  Gen( fn(r, size)
         val (r1, x) = (ga.generate)(r, size)
         val (r2, y) = (gb.generate)(r1, size)
         (r2, (x, y))
     , fn(p) (ga.shrink)(p.fst).map(fn(x) (x, p.snd)) ++
             (gb.shrink)(p.snd).map(fn(y) (p.fst, y))
     , fn(p) "(" ++ (ga.display)(p.fst) ++ "," ++ (gb.display)(p.snd) ++ ")" )

// ----------------------------------------------------------------------------
// Running a property
// ----------------------------------------------------------------------------

// Check that `prop` holds for `runs` generated values.
//
// On failure the counterexample is shrunk and the *shrunk* value is reported
// together with the seed, so the exact run can be replayed.
pub fun check( g : gen<a>, prop : (a) -> io bool,
               runs : int = 100, seed : int = 0x5EED, max-size : int = 60 ) : io ()
  run-checks(g, prop, rng(seed), runs, 0, max-size, seed)

fun run-checks( g : gen<a>, prop : (a) -> io bool, r : rng,
                runs : int, i : int, max-size : int, seed : int ) : io ()
  if i >= runs then ()
  else
    // grow the size with the run number so small cases are tried first
    val size = 1 + ((i * max-size) / max(runs, 1))
    val (r1, x) = (g.generate)(r, size)
    val held = safe-prop(prop, x)
    if held then run-checks(g, prop, r1, runs, i + 1, max-size, seed)
    else
      val small = shrink-to-failure(g, prop, x, 0)
      assert-fail("property failed after " ++ (i + 1).show ++ " runs (seed " ++ seed.show ++ ")" ++
                  "\n  counterexample: " ++ (g.display)(small) ++
                  (if (g.display)(small) == (g.display)(x) then ""
                   else "\n  original:       " ++ (g.display)(x)))

// A property that throws counts as failing, not as an error in the harness.
fun safe-prop( prop : (a) -> io bool, x : a ) : io bool
  match try({ prop(x) })
    Ok(b)     -> b
    Error(_)  -> False

// Greedily take the first simpler candidate that still fails, until no
// candidate does.  `depth` bounds the walk so a bad `shrink` cannot hang the
// test run.
fun shrink-to-failure( g : gen<a>, prop : (a) -> io bool, x : a, depth : int ) : io a
  if depth >= 200 then x
  else
    val failing = (g.shrink)(x).filter(fn(c) !safe-prop(prop, c))
    match failing
      Cons(c, _) -> shrink-to-failure(g, prop, c, depth + 1)
      Nil        -> x

// ----------------------------------------------------------------------------
// helpers
// ----------------------------------------------------------------------------

fun distinct-ints( xs : list<int> ) : list<int>
  xs.foldl([], fn(acc, x) if acc.any(fn(y) y == x) then acc else acc ++ [x])

fun distinct-strings( xs : list<string> ) : list<string>
  xs.foldl([], fn(acc, x) if acc.any(fn(y) y == x) then acc else acc ++ [x])
