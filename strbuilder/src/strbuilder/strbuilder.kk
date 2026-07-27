/* An efficient string builder.

   Repeated `s := s ++ x` in a loop is O(n^2): each step copies everything
   built so far.  This builder appends into a growable buffer instead, so
   building an n-character string costs O(n) rather than O(n^2).  It is what
   the JSON generator, the HTTP response writer, and the logger use.

   ## Representation

   A `bytes/builder` underneath, so the accumulated text is UTF-8 the whole
   way and `finish-bytes` can hand it straight to a socket without another
   copy.  `finish` decodes back to a `:string`.

   Everything `append`, `append-char`, `append-int`, `append-line`,
   `append-join` and the escapers put in the buffer is a `:string` or an escape
   sequence this module produced, so it is valid UTF-8.  `append-bytes` is the
   one door through which arbitrary octets enter, and it does not check them:
   `finish` therefore decodes *lossily*, and octets that are not valid UTF-8
   come back as U+FFFD rather than failing.  A caller that must not lose them
   should use `finish-bytes`, which hands over the octets undecoded.

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

pub fun is-notempty( b : strbuilder ) : bool
  b.length != 0

// Ensure room for at least `n` additional octets.
pub fun reserve( b : strbuilder, n : int ) : strbuilder
  Strbuilder(b.buf.reserve(n))

// ----------------------------------------------------------------------------
// appending
// ----------------------------------------------------------------------------

pub fun append( b : strbuilder, s : string ) : strbuilder
  Strbuilder(b.buf.snoc-string(s))

pub fun append-char( b : strbuilder, c : char ) : strbuilder
  b.append(c.string)

pub fun append-int( b : strbuilder, i : int ) : strbuilder
  b.append(i.show)

// Append any value that supplies the usual `show` operation.
pub fun append-show( b : strbuilder, x : a, ?show : a -> string ) : div strbuilder
  b.append(show(x))

pub fun append-bytes( b : strbuilder, x : bytes ) : strbuilder
  Strbuilder(b.buf.snoc(x))

pub fun append-line( b : strbuilder, s : string = "" ) : strbuilder
  b.append(s).append("\n")

// Append `s` `n` times. Non-positive counts append nothing.
pub fun append-repeat( b : strbuilder, s : string, n : int ) : div strbuilder
  append-repeat-go(b, s, max(0, n))

fun append-repeat-go( b : strbuilder, s : string, n : int ) : div strbuilder
  if n <= 0 then b else append-repeat-go(b.append(s), s, n - 1)

pub fun append-if( b : strbuilder, condition : bool, s : string ) : strbuilder
  if condition then b.append(s) else b

// Append each of `parts` with `sep` between them.
pub fun append-join( b : strbuilder, parts : list<string>, sep : string = "" ) : div strbuilder
  match parts
    Nil            -> b
    Cons(p, Nil)   -> b.append(p)
    Cons(p, rest)  -> b.append(p).append(sep).append-join(rest, sep)

// Append every part followed by a newline.
pub fun append-lines( b : strbuilder, parts : list<string> ) : div strbuilder
  parts.foldl(b, fn(acc, part) acc.append-line(part))

// ----------------------------------------------------------------------------
// escaping
//
// JSON string escaping per RFC 8259: the two mandatory escapes, the control
// characters below U+0020, and the short forms for the common ones.  `/` is
// not escaped (it is optional) and non-ASCII characters are emitted as UTF-8
// rather than \u sequences, which is valid JSON and much smaller.
// ----------------------------------------------------------------------------

// Escaped, one `append` per *run* of characters that need no escaping rather
// than one per character.  Each `append` crosses into C, and that cost must be
// paid per run, not per character -- for the common value, which needs no
// escaping at all, this is a single append of the whole string.
pub fun append-json-escaped( b : strbuilder, s : string ) : div strbuilder
  // `run` holds the pending unescaped characters, most recent first
  fun flush( acc : strbuilder, run : list<char> ) : strbuilder
    match run
      Nil        -> acc
      Cons(_, _) -> acc.append(run.reverse.string)
  fun go( acc : strbuilder, cs : list<char>, run : list<char> ) : div strbuilder
    match cs
      Nil -> flush(acc, run)
      Cons(c, rest) ->
        match c.json-escape
          Nothing  -> go(acc, rest, Cons(c, run))
          Just(esc) -> go(flush(acc, run).append(esc), rest, Nil)
  go(b, s.list, Nil)

// What to write instead of `c`, or `Nothing` when `c` is written as itself.
// The `:maybe` is what lets the caller batch: "needs no escaping" is the
// answer for almost every character, and those go out in one piece.
fun json-escape( c : char ) : maybe<string>
  match c
    '"'  -> Just("\\\"")
    '\\' -> Just("\\\\")
    '\n' -> Just("\\n")
    '\r' -> Just("\\r")
    '\t' -> Just("\\t")
    _ ->
      // the remaining escapes are the other control characters below U+0020
      val n = c.int
      if n == 8 then Just("\\b")
      elif n == 12 then Just("\\f")
      elif n < 0x20 then Just("\\u" ++ n.show-hex(4, use-capitals = False, pre = ""))
      else Nothing

// A string wrapped in quotes with its contents escaped.
pub fun append-json-string( b : strbuilder, s : string ) : div strbuilder
  b.append("\"").append-json-escaped(s).append("\"")

// ----------------------------------------------------------------------------
// finishing
// ----------------------------------------------------------------------------

// The accumulated text.  The builder is left empty and can be reused.
pub fun finish( b : strbuilder ) : strbuilder-result
  b.buf.finish.to-string-lossy

pub alias strbuilder-result = string

// Decode strictly. This differs from `finish` only when arbitrary invalid
// octets entered through `append-bytes`.
pub fun finish-checked( b : strbuilder ) : maybe<string>
  b.buf.finish.to-string

// The accumulated octets, without decoding.  Use this when the next step is
// a socket write: it avoids a decode and a re-encode.
pub fun finish-bytes( b : strbuilder ) : bytes
  b.buf.finish

// Build a string with `action`, which is the common shape.
pub fun build( action : (strbuilder) -> e strbuilder, capacity : int = 256 ) : e string
  action(strbuilder(capacity)).finish

// Build bytes directly, avoiding a decode when the consumer is byte-oriented.
pub fun build-bytes( action : (strbuilder) -> e strbuilder,
                     capacity : int = 256 ) : e bytes
  action(strbuilder(capacity)).finish-bytes
