/* Immutable byte sequences.

   Backed by `kk_bytes_t`, the runtime's own byte-sequence block, so a `:bytes`
   is an ordinary reference-counted Koka value: sharing it is free, and it is
   released when the last reference goes away.  There is no manual free.

   ## Ownership and sharing

   `:bytes` is immutable and persistent.  Passing one around copies a pointer
   and bumps a reference count; it never copies the payload.  Every operation
   that would change content returns a new value.

   ## Copying

   * `cat` allocates a new sequence and copies both operands.
   * `slice` allocates and copies the selected range.  It is *not* a view, so a
     small slice of a large buffer does not keep the large buffer alive.
   * `from-string` / `to-string` copy.

   ## Complexity

   | operation        | cost                      |
   | ---------------- | ------------------------- |
   | `length`, `at`   | O(1)                      |
   | `cat`            | O(n+m), allocates         |
   | `slice`          | O(len), allocates         |
   | `(==)`           | O(n), early exit on length|
   | `compare`        | O(n), no early exit       |
   | `hash`           | O(n)                      |

   Building a sequence by repeated `cat` is O(n^2); use `bytes/builder` for
   that, which is what it exists for.

   ## Invalid UTF-8

   `:bytes` holds arbitrary octets, including NUL and sequences that are not
   valid UTF-8.  `to-string` therefore returns a `:maybe` and yields `Nothing`
   for input that is not valid UTF-8; `to-string-lossy` replaces every invalid
   sequence with U+FFFD.  Nothing in this module ever produces a `:string`
   holding invalid UTF-8.

   ## Maximum size

   A sequence is limited by `kk_ssize_t`, so in practice by available memory.
   A builder that cannot grow aborts the process with a message on stderr; it
   does not truncate.  A short response that looks complete is worse than a
   crash, and under mimalloc an allocation failure is not survivable anyway.
   This is deliberately not an exception: that would put `exn` in the row of
   every `snoc`, and so of every caller of the JSON generator and the HTTP
   response writer.
*/
module bytes/bytes

import std/num/int32
import std/num/int64

extern import
  c file "bytes-inline.c"

// An immutable sequence of octets.
abstract value struct bytes( rep : any )

// ----------------------------------------------------------------------------
// low-level interoperation
//
// A `:bytes` is a boxed `kk_bytes_t`.  Other packages that bind C functions
// producing or consuming byte sequences need to move between the two, and the
// struct itself stays abstract so that nothing else can.
//
// These are safe as long as the `any` really is a boxed `kk_bytes_t`, which is
// why they are named for the care they require.
// ----------------------------------------------------------------------------

pub fun unsafe-bytes-from-raw( r : any ) : bytes
  Bytes(r)

pub fun unsafe-bytes-raw( b : bytes ) : any
  b.rep

// ----------------------------------------------------------------------------
// construction
// ----------------------------------------------------------------------------

pub val bytes-empty : bytes = Bytes(prim-empty())

// UTF-8 encoding of `s`.  Always succeeds.
pub fun string/bytes( s : string ) : bytes
  Bytes(prim-of-string(s))

// A sequence of `n` copies of `b` (0..255; other values are taken modulo 256).
pub fun replicate( b : int, n : int ) : bytes
  Bytes(prim-replicate(b.int32, n.ssize_t))

// From a list of octets (0..255; other values are taken modulo 256).
pub fun list/bytes( xs : list<int> ) : bytes
  xs.foldl(builder-empty(), fn(acc, x) acc.snoc-byte(x)).finish

// ----------------------------------------------------------------------------
// inspection
// ----------------------------------------------------------------------------

pub fun length( b : bytes ) : int
  prim-length(b.rep).int

pub fun is-empty( b : bytes ) : bool
  b.length == 0

pub fun is-notempty( b : bytes ) : bool
  b.length != 0

// The octet at `i` as a value in 0..255, or `Nothing` when out of range.
pub fun at( b : bytes, i : int ) : maybe<int>
  if i < 0 || i >= b.length then Nothing
  else Just(prim-at(b.rep, i.ssize_t).int)

// The octet at `i`, throwing when out of range.
pub fun at-exn( b : bytes, i : int ) : exn int
  match b.at(i)
    Just(x)  -> x
    Nothing  -> throw("bytes index out of range: " ++ i.show ++
                      " (length " ++ b.length.show ++ ")", ExnRange)

pub fun list( b : bytes ) : list<int>
  list(0, b.length - 1).map(fn(i) prim-at(b.rep, i.ssize_t).int)

// ----------------------------------------------------------------------------
// combining
// ----------------------------------------------------------------------------

pub fun (++)( a : bytes, b : bytes ) : bytes
  Bytes(prim-cat(a.rep, b.rep))

pub fun cat( a : bytes, b : bytes ) : bytes
  a ++ b

pub fun concat( xs : list<bytes> ) : bytes
  xs.foldl(builder-empty(), fn(acc, x) acc.snoc(x)).finish

// `count` octets starting at `start`, clamped to the sequence.  A copy, except
// that asking for the whole sequence hands back the same value.
pub fun slice( b : bytes, start : int, count : int = -1 ) : bytes
  val n     = b.length
  val from  = max(0, min(start, n))
  val want  = if count < 0 then n - from else count
  val len   = max(0, min(want, n - from))
  if from == 0 && len == n then b
  else Bytes(prim-slice(b.rep, from.ssize_t, len.ssize_t))

pub fun take( b : bytes, n : int ) : bytes
  b.slice(0, n)

pub fun drop( b : bytes, n : int ) : bytes
  b.slice(n)

pub fun starts-with( b : bytes, pre : bytes ) : bool
  pre.length <= b.length && b.take(pre.length) == pre

// Index of the first occurrence of `sub`, or `Nothing`.
pub fun index-of( b : bytes, sub : bytes, from : int = 0 ) : maybe<int>
  val i = prim-index-of(b.rep, sub.rep, max(0, from).ssize_t).int
  if i < 0 then Nothing else Just(i)

// Split on a single octet separator.  The result always has one more element
// than there are separators, so `split` of an empty sequence is `[empty]`.
pub fun split( b : bytes, sep : int ) : div list<bytes>
  split-from(b, sep, 0, [])

fun split-from( b : bytes, sep : int, from : int, acc : list<bytes> ) : div list<bytes>
  match b.index-of(replicate(sep, 1), from)
    Nothing -> (Cons(b.slice(from), acc)).reverse
    Just(i) -> split-from(b, sep, i + 1, Cons(b.slice(from, i - from), acc))

// ----------------------------------------------------------------------------
// conversion to text
// ----------------------------------------------------------------------------

// Decode as UTF-8.  `Nothing` when the octets are not valid UTF-8, so invalid
// input can never masquerade as a `:string`.
pub fun to-string( b : bytes ) : maybe<string>
  if prim-is-utf8(b.rep) then Just(prim-to-string-lossy(b.rep)) else Nothing

// Decode as UTF-8, replacing every invalid sequence with U+FFFD.
pub fun to-string-lossy( b : bytes ) : string
  prim-to-string-lossy(b.rep)

// Lowercase hexadecimal, two characters per octet.  Handy in tests and logs.
pub fun to-hex( b : bytes ) : string
  prim-to-hex(b.rep)

// ----------------------------------------------------------------------------
// equality, ordering, hashing
// ----------------------------------------------------------------------------

pub fun (==)( a : bytes, b : bytes ) : bool
  prim-eq(a.rep, b.rep)

pub fun (!=)( a : bytes, b : bytes ) : bool
  !(a == b)

pub fun compare( a : bytes, b : bytes ) : order
  val c = prim-cmp(a.rep, b.rep).int
  if c < 0 then Lt elif c > 0 then Gt else Eq

// FNV-1a over the octets.  Not a cryptographic hash and not offered as one;
// it exists so `:bytes` can be a hash-map key.
pub fun hash( b : bytes ) : int
  prim-hash(b.rep).int

pub fun show( b : bytes ) : string
  "bytes(" ++ b.length.show ++ ")[" ++ b.to-hex ++ "]"

// ----------------------------------------------------------------------------
// integer encoding helpers
//
// Fixed-width, explicit endianness.  Reads are bounds checked and return
// `:maybe` rather than reading past the end.
// ----------------------------------------------------------------------------

pub fun be16( v : int ) : bytes
  bytes([ (v / 256) % 256, v % 256 ])

pub fun be32( v : int ) : bytes
  bytes([ (v / 16777216) % 256, (v / 65536) % 256, (v / 256) % 256, v % 256 ])

pub fun le16( v : int ) : bytes
  bytes([ v % 256, (v / 256) % 256 ])

pub fun le32( v : int ) : bytes
  bytes([ v % 256, (v / 256) % 256, (v / 65536) % 256, (v / 16777216) % 256 ])

pub fun read-be16( b : bytes, pos : int = 0 ) : maybe<int>
  match (b.at(pos), b.at(pos + 1))
    (Just(h), Just(l)) -> Just(h * 256 + l)
    _ -> Nothing

pub fun read-be32( b : bytes, pos : int = 0 ) : maybe<int>
  match (b.read-be16(pos), b.read-be16(pos + 2))
    (Just(h), Just(l)) -> Just(h * 65536 + l)
    _ -> Nothing

pub fun read-le16( b : bytes, pos : int = 0 ) : maybe<int>
  match (b.at(pos), b.at(pos + 1))
    (Just(l), Just(h)) -> Just(h * 256 + l)
    _ -> Nothing

pub fun read-le32( b : bytes, pos : int = 0 ) : maybe<int>
  match (b.read-le16(pos), b.read-le16(pos + 2))
    (Just(l), Just(h)) -> Just(h * 65536 + l)
    _ -> Nothing

// ----------------------------------------------------------------------------
// builder
//
// An append-only buffer with amortized O(1) append, so building a large
// sequence is linear instead of quadratic.  The buffer is a native block whose
// lifetime is managed by the runtime: it is freed when the builder value is
// dropped, and `finish` hands over the accumulated octets.
//
// A builder is *linear by convention*: each operation returns the builder and
// the previous value must not be used again.  Using a stale builder value is
// not detected and will append to the same buffer, which is why every function
// here takes and returns the builder rather than mutating in place invisibly.
// ----------------------------------------------------------------------------

abstract value struct builder( buf : any )

// A builder with room for `capacity` octets before its first growth.
pub fun builder-empty( capacity : int = 64 ) : builder
  Builder(prim-builder-new(max(0, capacity).ssize_t))

// Ensure room for at least `n` more octets without reallocating.
pub fun reserve( b : builder, n : int ) : builder
  prim-builder-reserve(b.buf, max(0, n).ssize_t)
  b

pub fun snoc-byte( b : builder, x : int ) : builder
  prim-builder-push(b.buf, x.int32)
  b

pub fun snoc( b : builder, x : bytes ) : builder
  prim-builder-append(b.buf, x.rep)
  b

pub fun snoc-string( b : builder, s : string ) : builder
  prim-builder-append-string(b.buf, s)
  b

pub fun builder/length( b : builder ) : int
  prim-builder-length(b.buf).int

// The accumulated octets.  The builder is left empty and can be reused.
pub fun finish( b : builder ) : bytes
  Bytes(prim-builder-finish(b.buf))

// ----------------------------------------------------------------------------
// primitives
// ----------------------------------------------------------------------------

extern prim-empty() : any
  c "kk_bytesx_empty"
extern prim-of-string( s : string ) : any
  c "kk_bytesx_of_string"
extern prim-replicate( b : int32, n : ssize_t ) : any
  c "kk_bytesx_replicate"
extern prim-length( b : any ) : ssize_t
  c "kk_bytesx_length"
extern prim-at( b : any, i : ssize_t ) : int32
  c "kk_bytesx_at"
extern prim-cat( a : any, b : any ) : any
  c "kk_bytesx_cat"
extern prim-slice( b : any, start : ssize_t, len : ssize_t ) : any
  c "kk_bytesx_slice"
extern prim-index-of( b : any, sub : any, from : ssize_t ) : ssize_t
  c "kk_bytesx_index_of"
extern prim-is-utf8( b : any ) : bool
  c "kk_bytesx_is_utf8"
extern prim-to-string-lossy( b : any ) : string
  c "kk_bytesx_to_string_lossy"
extern prim-to-hex( b : any ) : string
  c "kk_bytesx_to_hex"
extern prim-eq( a : any, b : any ) : bool
  c "kk_bytesx_eq"
extern prim-cmp( a : any, b : any ) : int32
  c "kk_bytesx_cmp"
extern prim-hash( b : any ) : ssize_t
  c "kk_bytesx_hash"

extern prim-builder-new( capacity : ssize_t ) : any
  c "kk_bytesx_builder_new"
extern prim-builder-reserve( b : any, n : ssize_t ) : ()
  c "kk_bytesx_builder_reserve"
extern prim-builder-push( b : any, x : int32 ) : ()
  c "kk_bytesx_builder_push"
extern prim-builder-append( b : any, x : any ) : ()
  c "kk_bytesx_builder_append"
extern prim-builder-append-string( b : any, s : string ) : ()
  c "kk_bytesx_builder_append_string"
extern prim-builder-length( b : any ) : ssize_t
  c "kk_bytesx_builder_length"
extern prim-builder-finish( b : any ) : any
  c "kk_bytesx_builder_finish"
