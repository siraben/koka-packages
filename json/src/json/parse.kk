/* A JSON parser with explicit limits and source positions.

   Written against `:bytes` rather than `:string` because that is what arrives
   from a socket, and because a document that is not valid UTF-8 must be
   rejected as malformed input rather than crash a decoder.

   ## Limits

   Every limit is explicit and enforced *while* parsing, so a hostile document
   is rejected before it can cost anything:

   | limit           | default | why                                        |
   | --------------- | ------- | ------------------------------------------ |
   | `max-bytes`     | 1 MiB   | bounds the work a single document can cause |
   | `max-depth`     | 64      | bounds recursion, so nesting cannot exhaust the stack |
   | `max-members`   | 10000   | bounds one object or array                 |
   | `max-string`    | 65536   | bounds one string                          |

   ## Errors

   Every failure carries a byte offset, a line and a column, so a caller can
   point at the problem.  Offsets are into the *input bytes*; the line and
   column count characters, with a tab counting as one.

   ## Duplicate keys

   The policy is explicit and configurable, because silently picking one is a
   security-relevant surprise:

   * `DuplicateReject` (default) -- a duplicate key is an error.
   * `DuplicateFirst`  -- the first occurrence wins.
   * `DuplicateLast`   -- the last occurrence wins.

   ## Numbers

   Only integers are accepted.  A fractional or exponent form is reported as
   an error naming the offending token rather than being rounded, because a
   service that silently truncates a price is worse than one that rejects it.

   ## UTF-8

   The whole document is validated as UTF-8 before parsing.  Inside strings,
   `\uXXXX` escapes are decoded, including surrogate pairs; an unpaired
   surrogate is an error.
*/
module json/parse

import bytes/bytes
import hashmap/set
import strbuilder/strbuilder
import json/value

pub type duplicate-policy
  DuplicateReject
  DuplicateFirst
  DuplicateLast

pub struct limits
  max-bytes   : int
  max-depth   : int
  max-members : int
  max-string  : int
  duplicates  : duplicate-policy

pub val default-limits : limits
  = Limits(1024 * 1024, 64, 10000, 65536, DuplicateReject)

// A parse failure: what went wrong and where.
pub struct json-error
  message : string
  offset  : int
  line    : int
  column  : int

pub fun show( e : json-error ) : string
  e.message ++ " at line " ++ e.line.show ++ ", column " ++ e.column.show ++
  " (byte " ++ e.offset.show ++ ")"

// Parser state: the input, the current offset, and the limits.
struct pstate
  src    : bytes
  pos    : int
  lim    : limits

alias presult<a> = either<json-error, (a, pstate)>

// Continue with a successful result, or stop at the first error.
//
// Written so it composes with `with`: `with x <- p.and-then` reads as "let x be
// what p produced, and if p failed, return that failure".  Chaining parsers by
// hand produced a staircase of `match ... Left(e) -> Left(e)` one level deeper
// per step, where the only interesting line was the last one.
pub fun and-then( r : either<e,a>, next : (a) -> <div|f> either<e,b> ) : <div|f> either<e,b>
  match r
    Left(x)  -> Left(x)
    Right(v) -> next(v)

// ----------------------------------------------------------------------------
// entry points
// ----------------------------------------------------------------------------

// Parse a complete document.  Trailing content other than whitespace is an
// error, so a request body cannot smuggle a second document.
pub fun parse( input : bytes, lim : limits = default-limits ) : div either<json-error, json>
  if input.length > lim.max-bytes then
    Left(Json-error("document is larger than the " ++ lim.max-bytes.show ++ " byte limit",
                    0, 1, 1))
  elif !input.is-valid-utf8 then
    Left(Json-error("document is not valid UTF-8", 0, 1, 1))
  else
    val st = Pstate(input, 0, lim)
    with (v, st1) <- parse-value(skip-ws(st), 0).and-then
    val st2 = skip-ws(st1)
    if st2.pos < st2.src.length
      then Left(err(st2, "unexpected trailing input"))
      else Right(v)

pub fun parse-string( input : string, lim : limits = default-limits ) : div either<json-error, json>
  parse(bytes(input), lim)

// True when the whole input decodes as UTF-8.
fun is-valid-utf8( b : bytes ) : bool
  b.to-string.is-just

// ----------------------------------------------------------------------------
// positions and errors
// ----------------------------------------------------------------------------

fun err( st : pstate, msg : string ) : div json-error
  val (l, c) = line-col(st.src, st.pos)
  Json-error(msg, st.pos, l, c)

// Count lines and columns up to `upto`.  Only called when reporting an error,
// so the linear scan costs nothing on the success path.
fun line-col( b : bytes, upto : int ) : div (int, int)
  count(b, 0, upto, 1, 1)

fun count( b : bytes, i : int, upto : int, line : int, col : int ) : div (int, int)
  if i >= upto then (line, col)
  else match b.at(i)
         Just(10) -> count(b, i + 1, upto, line + 1, 1)          // '\n'
         Just(c)  -> if c >= 0x80 && c < 0xC0
                       then count(b, i + 1, upto, line, col)      // continuation octet
                       else count(b, i + 1, upto, line, col + 1)
         Nothing  -> (line, col)

// ----------------------------------------------------------------------------
// lexing helpers
// ----------------------------------------------------------------------------

fun peek( st : pstate ) : maybe<int>
  st.src.at(st.pos)

fun advance( st : pstate, n : int = 1 ) : pstate
  st(pos = st.pos + n)

fun at-end( st : pstate ) : bool
  st.pos >= st.src.length

fun skip-ws( st : pstate ) : div pstate
  match st.peek
    Just(32) -> skip-ws(st.advance)      // space
    Just(9)  -> skip-ws(st.advance)      // tab
    Just(10) -> skip-ws(st.advance)      // newline
    Just(13) -> skip-ws(st.advance)      // carriage return
    _        -> st

fun expect( st : pstate, byte : int, what : string ) : div either<json-error, pstate>
  match st.peek
    Just(c) | c == byte -> Right(st.advance)
    _ -> Left(err(st, "expected " ++ what))

// ----------------------------------------------------------------------------
// values
// ----------------------------------------------------------------------------

fun parse-value( st : pstate, depth : int ) : div presult<json>
  // `depth` is 0-based, so `depth >= max-depth` is what makes `max-depth = 5`
  // permit five levels of nesting rather than six.
  if depth >= st.lim.max-depth then
    Left(err(st, "nesting deeper than the limit of " ++ st.lim.max-depth.show))
  else match st.peek
    Nothing -> Left(err(st, "unexpected end of input"))
    Just(c) ->
      if c == 0x7B then parse-object(st.advance, depth)       // '{'
      elif c == 0x5B then parse-array(st.advance, depth)      // '['
      elif c == 0x22 then                                     // '"'
        with (s, st1) <- parse-string-literal(st.advance).and-then
        Right((JsString(s), st1))
      elif c == 0x74 then keyword(st, "true", JsBool(True))   // 't'
      elif c == 0x66 then keyword(st, "false", JsBool(False))
      elif c == 0x6E then keyword(st, "null", JsNull)         // 'n'
      elif c == 0x2D || (c >= 0x30 && c <= 0x39) then parse-number(st)
      else Left(err(st, "unexpected character"))

fun keyword( st : pstate, word : string, v : json ) : div presult<json>
  val w = bytes(word)
  if st.src.slice(st.pos, w.length) == w
    then Right((v, st.advance(w.length)))
    else Left(err(st, "expected " ++ word))

// ----------------------------------------------------------------------------
// numbers
// ----------------------------------------------------------------------------

fun parse-number( st : pstate ) : div presult<json>
  val start = st.pos
  val st1 = if st.peek == Just(0x2D) then st.advance else st      // '-'
  val st2 = skip-digits(st1)
  if st2.pos == st1.pos then Left(err(st, "expected a digit"))
  // RFC 8259 forbids a leading zero.  Accepting `01` where a validator, a
  // gateway or a signature check rejects it is a parser differential, and a
  // parser differential in front of a database write is how requests get
  // through checks that were supposed to stop them.
  elif st2.pos - st1.pos > 1 && st1.peek == Just(0x30) then
    Left(err(st1, "a number may not have a leading zero"))
  else match st2.peek
    // reject fractions and exponents explicitly rather than truncating
    Just(0x2E) -> Left(err(st2, "fractional numbers are not supported; use an integer"))
    Just(0x65) -> Left(err(st2, "exponent notation is not supported; use an integer"))
    Just(0x45) -> Left(err(st2, "exponent notation is not supported; use an integer"))
    _ ->
      val text = st.src.slice(start, st2.pos - start).to-string-lossy
      match text.parse-int
        Just(i) -> Right((JsInt(i), st2))
        Nothing -> Left(err(st, "malformed number " ++ text.show))

fun skip-digits( st : pstate ) : div pstate
  match st.peek
    Just(c) | c >= 0x30 && c <= 0x39 -> skip-digits(st.advance)
    _ -> st

// ----------------------------------------------------------------------------
// strings
// ----------------------------------------------------------------------------

// The opening quote has already been consumed.
fun parse-string-literal( st : pstate ) : div presult<string>
  scan(st, strbuilder(32), 0)

fun scan( st : pstate, acc : strbuilder, n : int ) : div presult<string>
  if n > st.lim.max-string then
    Left(err(st, "string is longer than the limit of " ++ st.lim.max-string.show))
  else match st.peek
    Nothing -> Left(err(st, "unterminated string"))
    Just(0x22) -> Right((acc.finish, st.advance))                 // closing quote
    Just(0x5C) -> parse-escape(st.advance, acc, n)                // backslash
    Just(c) ->
      if c < 0x20 then Left(err(st, "unescaped control character in a string"))
      else
        // Copy the raw octet; multi-byte sequences pass through unchanged
        // because the whole document was validated as UTF-8 up front.  `n`
        // counts *characters*, so a continuation octet does not advance it --
        // otherwise `max-string` would shrink to a quarter of its documented
        // value for text that happens to be emoji.
        val more = if c < 0x80 || c >= 0xC0 then 1 else 0
        scan(st.advance, acc.append-bytes(st.src.slice(st.pos, 1)), n + more)

fun parse-escape( st : pstate, acc : strbuilder, n : int ) : div presult<string>
  match st.peek
    Nothing -> Left(err(st, "unterminated escape"))
    Just(c) ->
      if c == 0x22 then scan(st.advance, acc.append("\""), n + 1)
      elif c == 0x5C then scan(st.advance, acc.append("\\"), n + 1)
      elif c == 0x2F then scan(st.advance, acc.append("/"), n + 1)
      elif c == 0x62 then scan(st.advance, acc.append-char(char(8)), n + 1)
      elif c == 0x66 then scan(st.advance, acc.append-char(char(12)), n + 1)
      elif c == 0x6E then scan(st.advance, acc.append("\n"), n + 1)
      elif c == 0x72 then scan(st.advance, acc.append("\r"), n + 1)
      elif c == 0x74 then scan(st.advance, acc.append("\t"), n + 1)
      elif c == 0x75 then parse-unicode-escape(st.advance, acc, n)
      else Left(err(st, "unknown escape"))

fun parse-unicode-escape( st : pstate, acc : strbuilder, n : int ) : div presult<string>
  with (cp, st1) <- hex4(st).and-then
  if cp >= 0xD800 && cp <= 0xDBFF then
    // high surrogate: a low surrogate must follow
    if !(st1.peek == Just(0x5C) && st1.advance.peek == Just(0x75)) then
      Left(err(st1, "unpaired high surrogate"))
    else
      with (lo, st2) <- hex4(st1.advance.advance).and-then
      if lo >= 0xDC00 && lo <= 0xDFFF then
        val full = 0x10000 + (cp - 0xD800) * 1024 + (lo - 0xDC00)
        scan(st2, acc.append-char(char(full)), n + 1)
      else Left(err(st1, "expected a low surrogate after a high surrogate"))
  elif cp >= 0xDC00 && cp <= 0xDFFF then
    Left(err(st, "unpaired low surrogate"))
  else
    scan(st1, acc.append-char(char(cp)), n + 1)

fun hex4( st : pstate ) : div either<json-error, (int, pstate)>
  match (hexdig(st, 0), hexdig(st, 1), hexdig(st, 2), hexdig(st, 3))
    (Just(a), Just(b), Just(c), Just(d)) ->
      Right((a * 4096 + b * 256 + c * 16 + d, st.advance(4)))
    _ -> Left(err(st, "expected four hexadecimal digits"))

fun hexdig( st : pstate, off : int ) : maybe<int>
  match st.src.at(st.pos + off)
    Just(c) | c >= 0x30 && c <= 0x39 -> Just(c - 0x30)
    Just(c) | c >= 0x61 && c <= 0x66 -> Just(c - 0x57)
    Just(c) | c >= 0x41 && c <= 0x46 -> Just(c - 0x37)
    _ -> Nothing

// ----------------------------------------------------------------------------
// arrays and objects
// ----------------------------------------------------------------------------

fun parse-array( st : pstate, depth : int ) : div presult<json>
  val st0 = skip-ws(st)
  if st0.peek == Just(0x5D) then Right((JsArray([]), st0.advance))   // ']'
  else array-items(st0, depth, [], 0)

fun array-items( st : pstate, depth : int, acc : list<json>, n : int ) : div presult<json>
  if n >= st.lim.max-members then
    Left(err(st, "array has more than the limit of " ++ st.lim.max-members.show ++ " elements"))
  else
    with (v, st1) <- parse-value(skip-ws(st), depth + 1).and-then
    val st2 = skip-ws(st1)
    match st2.peek
      Just(0x2C) -> array-items(st2.advance, depth, Cons(v, acc), n + 1)   // ','
      Just(0x5D) -> Right((JsArray(Cons(v, acc).reverse), st2.advance))    // ']'
      _ -> Left(err(st2, "expected ',' or ']'"))


fun parse-object( st : pstate, depth : int ) : div presult<json>
  val st0 = skip-ws(st)
  if st0.peek == Just(0x7D) then Right((JsObject([]), st0.advance))  // '}'
  else object-members(st0, depth, [], 0)

fun object-members( st : pstate, depth : int, acc : list<(string, json)>, n : int,
                    seen : hset<string> = set/empty() ) : div presult<json>
  if n >= st.lim.max-members then
    Left(err(st, "object has more than the limit of " ++ st.lim.max-members.show ++ " members"))
  else
    val st0 = skip-ws(st)
    with st1           <- st0.expect(0x22, "a string key").and-then   // '"'
    with (key, st2)    <- parse-string-literal(st1).and-then
    with st3           <- skip-ws(st2).expect(0x3A, "':'").and-then   // ':'
    with (v, st4)      <- parse-value(skip-ws(st3), depth + 1).and-then
    with (acc1, seen1) <- add-member(acc, seen, key, v, st.lim.duplicates)
                            .locate(st0).and-then
    val st5 = skip-ws(st4)
    match st5.peek
      Just(0x2C) -> object-members(st5.advance, depth, acc1, n + 1, seen1)  // ','
      Just(0x7D) -> Right((JsObject(acc1.reverse), st5.advance))            // '}'
      _ -> Left(err(st5, "expected ',' or '}'"))

// Attach a source position to a plain-text failure.
fun locate( r : either<string,a>, st : pstate ) : div either<json-error,a>
  match r
    Left(msg) -> Left(err(st, msg))
    Right(v)  -> Right(v)

// Keys are hashed through `bytes` rather than character by character; the
// implicit `?hash` on `hset` is resolved by this being named `string/hash`.
fun string/hash( s : string ) : int
  bytes(s).hash

// `acc` is in reverse order, so "first occurrence" is the one deepest in it.
//
// `seen` is what keeps membership O(1) and the whole object O(n).  Scanning
// `acc` for each key made it O(n^2): a 99 KB object of distinct keys -- a
// tenth of the default `max-bytes`, and exactly at the default `max-members`
// -- cost about four CPU-seconds, which on a single-threaded cooperative loop
// is four seconds during which the whole server serves nobody.
fun add-member( acc : list<(string, json)>, seen : hset<string>, key : string, v : json,
                policy : duplicate-policy )
    : div either<string, (list<(string, json)>, hset<string>)>
  if !set/member(seen, key, ?hash = string/hash) then
    Right((Cons((key, v), acc), set/insert(seen, key, ?hash = string/hash)))
  else match policy
    DuplicateReject -> Left("duplicate key " ++ key.show)
    DuplicateFirst  -> Right((acc, seen))
    DuplicateLast   -> Right((Cons((key, v), acc.filter(fn(kv) kv.fst != key)), seen))
