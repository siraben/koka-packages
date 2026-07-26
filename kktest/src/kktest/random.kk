/* A small deterministic pseudo-random generator for property testing.

   This is `splitmix64`: a well-known non-cryptographic generator chosen
   because it is a handful of lines, has no state beyond one 64-bit word, and
   produces the same stream on every machine -- which is what makes a failing
   property reproducible from its seed alone.

   It is not suitable for anything security related and is not offered as
   such.
*/
module kktest/random

import std/num/int64

// Generator state.  Threaded explicitly rather than hidden in a `ref`, so a
// generator is a pure function and a shrinking run can replay it.
pub value struct rng
  seed : int64

pub fun rng( seed : int = 0x2545F491 ) : rng
  Rng(seed.int64)

// splitmix64: advance the state, then mix it.
pub fun next( r : rng ) : (rng, int64)
  val s = r.seed + 0x9E3779B97F4A7C15.int64
  var z := s
  z := (z.xor(z.shr(30))) * 0xBF58476D1CE4E5B9.int64
  z := (z.xor(z.shr(27))) * 0x94D049BB133111EB.int64
  (Rng(s), z.xor(z.shr(31)))

// A non-negative `int` below `bound` (which must be positive).
pub fun next-below( r : rng, bound : int ) : (rng, int)
  val (r2, x) = r.next
  val v = x.shr(1).int      // drop the sign bit, then reduce
  (r2, if bound <= 0 then 0 else v % bound)

// An `int` in `[lo,hi]`.
pub fun next-range( r : rng, lo : int, hi : int ) : (rng, int)
  if hi <= lo then (r, lo)
  else
    val (r2, v) = r.next-below(hi - lo + 1)
    (r2, lo + v)

pub fun next-bool( r : rng ) : (rng, bool)
  val (r2, v) = r.next-below(2)
  (r2, v == 1)
