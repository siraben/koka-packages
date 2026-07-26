/* An efficient string builder.

   Repeated `s := s ++ x` in a loop is quadratic: each step copies everything
   built so far.  This builder appends into a growable buffer instead, so
   building an n-character string costs O(n) rather than O(n^2).  It is what
   the JSON generator, the HTTP response writer, and the logger use.

   ## Representation

   A `bytes/builder` underneath, so the accumulated text is UTF-8 the whole
   way and `finish-bytes` can hand it straight to a socket without another
   copy.  `finish` decodes back to a `:string`; because everything appended
   was either a `:string` or an escape sequence this module produced, the
   result is always valid UTF-8.

   ## Linearity

   Each operation returns the builder and the previous value must not be used
   again -- the underlying buffer is mutated in place.  Writing

       val b1 = b.append("a")
       val b2 = b.append("b")     // WRONG: b was already consumed

   appends both to the same buffer.  Threading the builder through, as every
   example here does, is the intended use.
*/
module strbuilder/strbuilder

import bytes/bytes

pub value struct strbuilder( buf : builder )

// A builder with room for `capacity` octets before its first growth.
pub fun strbuilder( capacity : int = 256 ) : strbuilder
  Strbuilder(builder-empty(capacity))

// Number of octets accumulated so far (not characters).
pub fun length( b : strbuilder ) : int
  b.buf.builder/length

pub fun is-empty( b : strbuilder ) : bool
  b.length == 0

// ----------------------------------------------------------------------------
// appending
// ----------------------------------------------------------------------------

pub fun append( b : strbuilder, s : string ) : strbuilder
  Strbuilder(b.buf.snoc-string(s))

pub fun append-char( b : strbuilder, c : char ) : strbuilder
  b.append(c.string)

pub fun append-int( b : strbuilder, i : int ) : strbuilder
  b.append(i.show)

pub fun append-bytes( b : strbuilder, x : bytes ) : strbuilder
  Strbuilder(b.buf.snoc(x))

pub fun append-line( b : strbuilder, s : string = "" ) : strbuilder
  b.append(s).append("\n")

// Append each of `parts` with `sep` between them.
pub fun append-join( b : strbuilder, parts : list<string>, sep : string = "" ) : div strbuilder
  match parts
    Nil            -> b
    Cons(p, Nil)   -> b.append(p)
    Cons(p, rest)  -> b.append(p).append(sep).append-join(rest, sep)

// ----------------------------------------------------------------------------
// escaping
//
// JSON string escaping per RFC 8259: the two mandatory escapes, the control
// characters below U+0020, and the short forms for the common ones.  `/` is
// not escaped (it is optional) and non-ASCII characters are emitted as UTF-8
// rather than \u sequences, which is valid JSON and much smaller.
// ----------------------------------------------------------------------------

pub fun append-json-escaped( b : strbuilder, s : string ) : div strbuilder
  s.list.foldl(b, fn(acc, c) acc.append-json-char(c))

fun append-json-char( b : strbuilder, c : char ) : strbuilder
  match c
    '"'  -> b.append("\\\"")
    '\\' -> b.append("\\\\")
    '\n' -> b.append("\\n")
    '\r' -> b.append("\\r")
    '\t' -> b.append("\\t")
    _ ->
      val n = c.int
      if n == 8 then b.append("\\b")
      elif n == 12 then b.append("\\f")
      elif n < 0x20 then b.append("\\u").append(hex4(n))
      else b.append-char(c)

// A string wrapped in quotes with its contents escaped.
pub fun append-json-string( b : strbuilder, s : string ) : div strbuilder
  b.append("\"").append-json-escaped(s).append("\"")

fun hex4( n : int ) : string
  val digits = "0123456789abcdef"
  fun d( shift : int ) : string
    val v = (n / shift) % 16
    match digits.list.drop(v)
      Cons(ch, _) -> ch.string
      Nil         -> "0"
  d(4096) ++ d(256) ++ d(16) ++ d(1)

// ----------------------------------------------------------------------------
// finishing
// ----------------------------------------------------------------------------

// The accumulated text.  The builder is left empty and can be reused.
pub fun finish( b : strbuilder ) : strbuilder-result
  b.buf.finish.to-string-lossy

pub alias strbuilder-result = string

// The accumulated octets, without decoding.  Use this when the next step is
// a socket write: it avoids a decode and a re-encode.
pub fun finish-bytes( b : strbuilder ) : bytes
  b.buf.finish

// Build a string with `action`, which is the common shape.
pub fun build( action : (strbuilder) -> e strbuilder, capacity : int = 256 ) : e string
  action(strbuilder(capacity)).finish
