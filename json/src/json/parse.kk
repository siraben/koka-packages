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

// ----------------------------------------------------------------------------
// the parser effect
//
// The position is the handler's business, so the grammar below is written in
// direct style and `run-parser` supplies the state.
//
// Every operation is `fun` -- tail-resumptive, compiled to a direct call with
// no continuation capture -- except `fail`, which is `ctl` and never resumes.
// JSON is LL(1), so nothing backtracks and nothing resumes twice.
// ----------------------------------------------------------------------------

// One effect, not two: splitting `fail` out so the rest could be `linear`
// measures 4-5% slower, because a function calling it is monadic whichever
// effect it lives in and a second handler adds evidence work.
//
// Granularity is what pays.  Each operation costs roughly ten times a plain
// byte read, so no per-byte work crosses this boundary: `plain-run`, `ws-end`
// and `digits-end` take the input and offset once, scan locally, and move the
// cursor once.
effect parser
  // the byte at the current position, or `Nothing` at end of input
  fun peek() : maybe<int>
  // the byte `off` ahead, for the fixed-width lookahead that escapes need
  fun peek-at( off : int ) : maybe<int>
  fun advance( n : int ) : ()
  fun offset() : int
  fun source() : bytes
  fun limits() : limits
  // abandon the parse; reports at the position reached so far
  ctl fail( msg : string ) : a

// Run `action` over `input`, turning a `fail` into a `Left`.
fun run-parser( input : bytes, lims : limits,
                action : () -> <parser,div|e> a ) : <div|e> either<json-error,a>
  var pos := 0
  with handler
    return(x)      Right(x)
    fun peek()     input.at(pos)
    fun peek-at(o) input.at(pos + o)
    fun advance(n) pos := pos + n
    fun offset()   pos
    fun source()   input
    fun limits()   lims
    ctl fail(msg)  Left(error-at(input, pos, msg))
  action()

// ----------------------------------------------------------------------------
// positions and errors
// ----------------------------------------------------------------------------

fun error-at( b : bytes, pos : int, msg : string ) : div json-error
  val (l, c) = line-col(b, pos)
  Json-error(msg, pos, l, c)

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
    with run-parser(input, lim)
    skip-ws()
    val v = parse-value(0)
    skip-ws()
    if offset() < source().length then fail("unexpected trailing input") else v

pub fun parse-string( input : string, lim : limits = default-limits ) : div either<json-error, json>
  parse(bytes(input), lim)

// True when the whole input decodes as UTF-8.
fun is-valid-utf8( b : bytes ) : bool
  b.to-string.is-just

// ----------------------------------------------------------------------------
// lexing helpers
// ----------------------------------------------------------------------------

fun skip-ws() : <parser,div> ()
  match peek()
    Just(32) -> skip-ws-run()
    Just(9)  -> skip-ws-run()
    Just(10) -> skip-ws-run()
    Just(13) -> skip-ws-run()
    _        -> ()                             // the common case: nothing to skip

fun skip-ws-run() : <parser,div> ()
  val src   = source()
  val start = offset()
  val stop  = ws-end(src, start)
  advance(stop - start)

fun ws-end( src : bytes, i : int ) : div int
  match src.at(i)
    Just(32) -> ws-end(src, i + 1)
    Just(9)  -> ws-end(src, i + 1)
    Just(10) -> ws-end(src, i + 1)
    Just(13) -> ws-end(src, i + 1)
    _        -> i

fun expect( byte : int, what : string ) : <parser,div> ()
  match peek()
    Just(c) | c == byte -> advance(1)
    _ -> fail("expected " ++ what)

// ----------------------------------------------------------------------------
// values
// ----------------------------------------------------------------------------

fun parse-value( depth : int ) : <parser,div> json
  // `depth` is 0-based, so `depth >= max-depth` is what makes `max-depth = 5`
  // permit five levels of nesting rather than six.
  val max-depth = limits().max-depth
  if depth >= max-depth then
    fail("nesting deeper than the limit of " ++ max-depth.show)
  else match peek()
    Nothing -> fail("unexpected end of input")
    Just(c) ->
      if c == 0x7B then { advance(1); parse-object(depth) }       // '{'
      elif c == 0x5B then { advance(1); parse-array(depth) }      // '['
      elif c == 0x22 then { advance(1); JsString(parse-string-literal()) }   // '"'
      elif c == 0x74 then keyword("true", JsBool(True))           // 't'
      elif c == 0x66 then keyword("false", JsBool(False))
      elif c == 0x6E then keyword("null", JsNull)                 // 'n'
      elif c == 0x2D || (c >= 0x30 && c <= 0x39) then parse-number()
      else fail("unexpected character")

fun keyword( word : string, v : json ) : <parser,div> json
  val w = bytes(word)
  if source().slice(offset(), w.length) == w
    then { advance(w.length); v }
    else fail("expected " ++ word)

// ----------------------------------------------------------------------------
// numbers
// ----------------------------------------------------------------------------

fun parse-number() : <parser,div> json
  val start = offset()
  if peek() == Just(0x2D) then advance(1)                         // '-'
  val digits-from = offset()
  skip-digits()
  val digits-to = offset()
  if digits-to == digits-from then fail("expected a digit")
  // RFC 8259 forbids a leading zero.  Accepting `01` where a validator, a
  // gateway or a signature check rejects it is a parser differential, and a
  // parser differential in front of a database write is how requests get
  // through checks that were supposed to stop them.
  elif digits-to - digits-from > 1 && source().at(digits-from) == Just(0x30) then
    fail("a number may not have a leading zero")
  else match peek()
    // reject fractions and exponents explicitly rather than truncating
    Just(0x2E) -> fail("fractional numbers are not supported; use an integer")
    Just(0x65) -> fail("exponent notation is not supported; use an integer")
    Just(0x45) -> fail("exponent notation is not supported; use an integer")
    _ ->
      val text = source().slice(start, digits-to - start).to-string-lossy
      match text.parse-int
        Just(i) -> JsInt(i)
        Nothing -> fail("malformed number " ++ text.show)

// Digits are counted locally and the cursor is moved once.  Every operation
// crossing the handler boundary costs about ten times a plain byte read, so
// per-byte work must not cross it -- that is the whole discipline that keeps
// this parser both direct-style and fast.
fun skip-digits() : <parser,div> ()
  val src   = source()
  val start = offset()
  val stop  = digits-end(src, start)
  advance(stop - start)

fun digits-end( src : bytes, i : int ) : div int
  match src.at(i)
    Just(c) | c >= 0x30 && c <= 0x39 -> digits-end(src, i + 1)
    _ -> i

// ----------------------------------------------------------------------------
// strings
// ----------------------------------------------------------------------------

// The opening quote has already been consumed.
fun parse-string-literal() : <parser,div> string
  scan(strbuilder(32), 0)

// Most of a string is ordinary characters, so they are copied a run at a time.
// Fetching the input and the limit once per run rather than per octet is what
// keeps this from paying a handler dispatch for every byte of a document.
fun scan( acc : strbuilder, n : int ) : <parser,div> string
  scan-loop(source(), limits().max-string, acc, n)

fun scan-loop( src : bytes, maxn : int, acc : strbuilder, n : int ) : <parser,div> string
  val start = offset()
  val (stop, chars) = plain-run(src, start, 0)
  val n1 = n + chars
  // checked against the whole run before anything is copied: `plain-run` only
  // computes offsets, so overshooting the limit costs nothing
  if n1 > maxn then fail("string is longer than the limit of " ++ maxn.show)
  else
    val acc1 = if stop > start
                 then { advance(stop - start); acc.append-bytes(src.slice(start, stop - start)) }
                 else acc
    match peek()
      Nothing    -> fail("unterminated string")
      Just(0x22) -> { advance(1); acc1.finish }                   // closing quote
      Just(0x5C) -> { advance(1); parse-escape(acc1, n1) }        // backslash
      Just(_)    -> fail("unescaped control character in a string")

// The longest run that can be copied verbatim: it stops at a quote, a
// backslash, a control character, or end of input.  Multi-byte sequences pass
// through unchanged because the document was validated as UTF-8 up front, and
// `chars` counts *characters*, so a continuation octet does not advance it --
// otherwise `max-string` would shrink to a quarter of its documented value for
// text that happens to be emoji.
fun plain-run( src : bytes, i : int, chars : int ) : div (int, int)
  match src.at(i)
    Nothing -> (i, chars)
    Just(c) -> if c == 0x22 || c == 0x5C || c < 0x20 then (i, chars)
               else plain-run(src, i + 1, chars + (if c < 0x80 || c >= 0xC0 then 1 else 0))

fun parse-escape( acc : strbuilder, n : int ) : <parser,div> string
  match peek()
    Nothing -> fail("unterminated escape")
    Just(c) ->
      if c == 0x22 then { advance(1); scan(acc.append("\""), n + 1) }
      elif c == 0x5C then { advance(1); scan(acc.append("\\"), n + 1) }
      elif c == 0x2F then { advance(1); scan(acc.append("/"), n + 1) }
      elif c == 0x62 then { advance(1); scan(acc.append-char(char(8)), n + 1) }
      elif c == 0x66 then { advance(1); scan(acc.append-char(char(12)), n + 1) }
      elif c == 0x6E then { advance(1); scan(acc.append("\n"), n + 1) }
      elif c == 0x72 then { advance(1); scan(acc.append("\r"), n + 1) }
      elif c == 0x74 then { advance(1); scan(acc.append("\t"), n + 1) }
      elif c == 0x75 then { advance(1); parse-unicode-escape(acc, n) }
      else fail("unknown escape")

fun parse-unicode-escape( acc : strbuilder, n : int ) : <parser,div> string
  val cp = hex4()
  if cp >= 0xD800 && cp <= 0xDBFF then
    // high surrogate: a low surrogate must follow
    if !(peek() == Just(0x5C) && peek-at(1) == Just(0x75)) then
      fail("unpaired high surrogate")
    else
      advance(2)
      val lo = hex4()
      if lo >= 0xDC00 && lo <= 0xDFFF then
        val full = 0x10000 + (cp - 0xD800) * 1024 + (lo - 0xDC00)
        scan(acc.append-char(char(full)), n + 1)
      else fail("expected a low surrogate after a high surrogate")
  elif cp >= 0xDC00 && cp <= 0xDFFF then
    fail("unpaired low surrogate")
  else
    scan(acc.append-char(char(cp)), n + 1)

fun hex4() : <parser,div> int
  match (hexdig(0), hexdig(1), hexdig(2), hexdig(3))
    (Just(a), Just(b), Just(c), Just(d)) ->
      advance(4)
      a * 4096 + b * 256 + c * 16 + d
    _ -> fail("expected four hexadecimal digits")

fun hexdig( off : int ) : <parser,div> maybe<int>
  match peek-at(off)
    Just(c) | c >= 0x30 && c <= 0x39 -> Just(c - 0x30)
    Just(c) | c >= 0x61 && c <= 0x66 -> Just(c - 0x57)
    Just(c) | c >= 0x41 && c <= 0x46 -> Just(c - 0x37)
    _ -> Nothing

// ----------------------------------------------------------------------------
// arrays and objects
// ----------------------------------------------------------------------------

fun parse-array( depth : int ) : <parser,div> json
  skip-ws()
  if peek() == Just(0x5D) then { advance(1); JsArray([]) }        // ']'
  else array-items(depth, [], 0, limits().max-members)

fun array-items( depth : int, acc : list<json>, n : int, max-members : int ) : <parser,div> json
  if n >= max-members then
    fail("array has more than the limit of " ++ max-members.show ++ " elements")
  else
    skip-ws()
    val v = parse-value(depth + 1)
    skip-ws()
    match peek()
      Just(0x2C) -> { advance(1); array-items(depth, Cons(v, acc), n + 1, max-members) }  // ','
      Just(0x5D) -> { advance(1); JsArray(Cons(v, acc).reverse) }             // ']'
      _ -> fail("expected ',' or ']'")

fun parse-object( depth : int ) : <parser,div> json
  skip-ws()
  if peek() == Just(0x7D) then { advance(1); JsObject([]) }       // '}'
  else object-members(depth, [], 0, set/empty(), limits())

fun object-members( depth : int, acc : list<(string, json)>, n : int,
                    seen : hset<string>, lims : limits ) : <parser,div> json
  val max-members = lims.max-members
  if n >= max-members then
    fail("object has more than the limit of " ++ max-members.show ++ " members")
  else
    skip-ws()
    val key-at = offset()
    expect(0x22, "a string key")                                  // '"'
    val key = parse-string-literal()
    skip-ws()
    expect(0x3A, "':'")                                           // ':'
    skip-ws()
    val v = parse-value(depth + 1)
    val (acc1, seen1) = add-member(acc, seen, key, v, lims.duplicates, key-at)
    skip-ws()
    match peek()
      Just(0x2C) -> { advance(1); object-members(depth, acc1, n + 1, seen1, lims) }  // ','
      Just(0x7D) -> { advance(1); JsObject(acc1.reverse) }                     // '}'
      _ -> fail("expected ',' or '}'")

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
                policy : duplicate-policy, key-at : int )
    : <parser,div> (list<(string, json)>, hset<string>)
  if !set/member(seen, key, ?hash = string/hash) then
    (Cons((key, v), acc), set/insert(seen, key, ?hash = string/hash))
  else match policy
    DuplicateReject -> fail-at(key-at, "duplicate key " ++ key.show)
    DuplicateFirst  -> (acc, seen)
    DuplicateLast   -> (Cons((key, v), acc.filter(fn(kv) kv.fst != key)), seen)

// `fail` reports at the current position; a duplicate key is better reported
// where the key started than where the parser has since moved to.
fun fail-at( pos : int, msg : string ) : <parser,div> a
  val here = offset()
  advance(pos - here)
  fail(msg)
