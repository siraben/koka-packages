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
// Generator combinators
// ----------------------------------------------------------------------------

// A constant generator is useful for lifting edge cases into larger generated
// structures.  It cannot shrink: it is already the only value it can produce.
pub fun gen-const( value : a, ?show : a -> string ) : gen<a>
  Gen(fn(r, _size) (r, value), fn(_) [], fn(x) x.show)

// Transform a generator.  `unmap` is needed only for shrinking: it projects a
// generated value back to the source domain so the source shrinker remains
// useful.  For a one-way transform use `map-no-shrink`.
pub fun gen-map( source : gen<a>, project : (a) -> b, unmap : (b) -> a,
                 ?show : b -> string ) : gen<b>
  Gen( fn(r, size)
         val (r1, x) = (source.generate)(r, size)
         (r1, project(x))
     , fn(y) (source.shrink)(unmap(y)).map(project)
     , fn(y) y.show )

pub fun map-no-shrink( source : gen<a>, project : (a) -> b,
                       ?show : b -> string ) : gen<b>
  Gen( fn(r, size)
         val (r1, x) = (source.generate)(r, size)
         (r1, project(x))
     , fn(_) []
     , fn(y) y.show )

// Optional values, with `Nothing` as the simplest counterexample.  A frequency
// of zero means "always present"; otherwise roughly one in `nothing-every`
// generated values is absent.
pub fun gen-maybe( elem : gen<a>, nothing-every : int = 4 ) : gen<maybe<a>>
  Gen( fn(r, size)
         val (r1, absent) =
           if nothing-every <= 0 then (r, False)
           else
             val (r2, n) = r.next-below(nothing-every)
             (r2, n == 0)
         if absent then (r1, Nothing)
         else
           val (r2, x) = (elem.generate)(r1, size)
           (r2, Just(x))
     , fn(mx)
         { match mx
             Nothing -> []
             Just(x) -> [Nothing] ++ (elem.shrink)(x).map(Just)
         }
     , fn(mx)
         { match mx
             Nothing -> "Nothing"
             Just(x) -> "Just(" ++ (elem.display)(x) ++ ")"
         } )

// Select uniformly from one or more generators.  Taking the first choice
// separately makes an empty set of alternatives unrepresentable.
pub fun gen-one-of( first : gen<a>, rest : list<gen<a>> = [],
                    ?show : a -> string ) : gen<a>
  val choices = Cons(first, rest)
  Gen( fn(r, size)
         val (r1, n) = r.next-below(choices.length)
         match choices.drop(n)
           Cons(g, _) -> (g.generate)(r1, size)
           // `n` is below the non-empty list's length, so this cannot happen.
           Nil -> (first.generate)(r1, size)
     , fn(_) []
     , fn(x) x.show )

// ----------------------------------------------------------------------------
// Core generators
// ----------------------------------------------------------------------------

// Integers, shrinking towards zero.  A bound the caller did not give is
// `Nothing`, and the size budget chooses it: the default range grows with the
// run number, which is what the size is for.
//
// The size budget is *not* allowed to narrow a bound the caller did give.  It
// used to, and the fix that was supposed to remove that used the default value
// itself as the "caller said nothing" flag:
//
//     val l = if lo == -1000000 then max(lo, 0 - bound) else lo
//
// so `gen-int(-1000000, 500)` was still clamped to the size budget, silently.
// A generator that under-generates makes every property that uses it weaker
// than it reads, and nothing fails to say so -- which is why the absent bound
// is a `maybe` and not a number that could also be meant.
pub fun maybe/gen-int( lo : maybe<int> = Nothing, hi : maybe<int> = Nothing ) : gen<int>
  Gen( fn(r, size)
         val bound = max(size, 0)
         val l = match lo
                   Just(x) -> x
                   Nothing -> 0 - bound
         val h = match hi
                   Just(x) -> x
                   Nothing -> bound
         r.next-range(min(l, h), max(l, h))
     , shrink-int
     , fn(i) i.show )

// Integers in `[lo, hi]`, shrinking towards zero.  The size budget does not
// narrow this range: `gen-int(-500, 500)` really does generate -500 to 500.
pub fun range/gen-int( lo : int, hi : int ) : gen<int>
  maybe/gen-int(Just(lo), Just(hi))

fun shrink-int( i : int ) : list<int>
  if i == 0 then []
  else
    val halved = i / 2
    val cands  = [0, halved, i - (if i > 0 then 1 else -1)]
    cands.filter(fn(c) c != i).distinct

// Non-negative integers, shrinking towards zero.
//
// Unlike `gen-int`, an explicit `hi` here is an upper bound that the size
// budget may narrow further, so `gen-nat(50)` generates `[0, min(50, size)]`.
// That is the inconsistency it looks like; it is left alone because changing it
// changes what an existing caller outside this package generates, and no bound
// is being used as a flag here.
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
//
// This alphabet contains nothing that needs escaping and nothing outside
// ASCII, so a round-trip property checked with it never reaches an escape or a
// multi-byte path.  Use `gen-text` for anything about encoding.
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
    cands.filter(fn(c) c != s).distinct

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

// Strings that actually exercise escaping and UTF-8: quotes, backslashes,
// control characters, and characters that encode as two, three and four
// octets.  A "round trips through escaping" property is only worth anything
// when its inputs contain something to escape.
pub fun gen-text() : gen<string>
  gen-string("ab\"\\/\n\t\r" ++ string([char(1), char(31), char(127)]) ++ "\u00e9\u4e16\U01F600 ")

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

// How a run of a property did not hold.  A property that throws is not the
// same event as one that returns `False`: the exception is usually the whole
// diagnosis, and reporting it as a bare counterexample with no cause throws it
// away at the one moment it was worth something.
type prop-failure
  Falsified
  Threw( message : string )

// Check that `prop` holds for `runs` generated values.
//
// On failure the counterexample is shrunk and the *shrunk* value is reported
// together with the seed, so the exact run can be replayed.  A property that
// throws is reported as having thrown, with the exception's message.
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
    match run-prop(prop, x)
      Nothing   -> run-checks(g, prop, r1, runs, i + 1, max-size, seed)
      Just(why) ->
        val (small, why2) = shrink-to-failure(g, prop, x, why, 0)
        assert-fail(failure-report(g, x, small, why2, i + 1, seed))

// Run the property once.  `Nothing` means it held; anything else says how it
// did not, so a crash is never reported as a plain failed property.
fun run-prop( prop : (a) -> io bool, x : a ) : io maybe<prop-failure>
  match try({ prop(x) })
    Ok(True)   -> Nothing
    Ok(False)  -> Just(Falsified)
    Error(ex)  -> Just(Threw(ex.message))

fun failure-report( g : gen<a>, original : a, small : a, why : prop-failure,
                    runs : int, seed : int ) : string
  val headline = match why
                   Falsified -> "property failed after "
                   Threw(_)  -> "property threw after "
  val cause = match why
                Falsified -> ""
                Threw(m)  -> "\n  threw:          " ++ m
  headline ++ runs.show ++ " runs (seed " ++ seed.show ++ ")" ++
  "\n  counterexample: " ++ (g.display)(small) ++
  (if (g.display)(small) == (g.display)(original) then ""
   else "\n  original:       " ++ (g.display)(original)) ++
  cause

// Greedily take the first simpler candidate that still fails, until no
// candidate does, and carry back *why* that candidate failed.  `depth` bounds
// the walk so a bad `shrink` cannot hang the test run.
fun shrink-to-failure( g : gen<a>, prop : (a) -> io bool, x : a,
                       why : prop-failure, depth : int ) : io (a, prop-failure)
  if depth >= 200 then (x, why)
  else
    match first-failing(prop, (g.shrink)(x))
      Just((c, why2)) -> shrink-to-failure(g, prop, c, why2, depth + 1)
      Nothing         -> (x, why)

// The first candidate that does not hold, and why.  Candidates are tried one
// at a time and the walk stops at the first failure, so an expensive property
// is not run on every candidate to then use only the first.
fun first-failing( prop : (a) -> io bool, cands : list<a> ) : io maybe<(a, prop-failure)>
  match cands
    Nil -> Nothing
    Cons(c, rest) ->
      match run-prop(prop, c)
        Just(why) -> Just((c, why))
        Nothing   -> first-failing(prop, rest)

// ----------------------------------------------------------------------------
// helpers
// ----------------------------------------------------------------------------

// Duplicates removed, keeping the first occurrence and the order.
//
// One function with an implicit `(==)` rather than one per element type: the
// int and string copies this replaces differed only in which `(==)` they
// closed over.
//
// The scan is linear per element and so quadratic overall.  It stays that way
// deliberately: the only callers are the shrink-candidate lists above, which
// hold three or four elements, and the obvious fix -- `hashmap/set` -- is not
// reachable from here, because `hashmap` depends on `kktest` and not the other
// way round.
fun distinct( xs : list<a>, ?(==) : (a,a) -> bool ) : list<a>
  xs.foldl([], fn(acc, x) if acc.any(fn(y) y == x) then acc else Cons(x, acc)).reverse
