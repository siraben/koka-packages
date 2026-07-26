/* HTTP/1.1 messages: the subset the reference service needs.

   Parsing works on `:bytes` and is incremental: `parse` is handed whatever the
   socket produced and reports whether a complete request has arrived, so the
   server never has to guess how much to read.

   ## Limits

   Every limit is checked *while* parsing, so a hostile client is rejected
   before it can cost anything.  All of them count octets, not characters, and
   the request line and the header block are bounded separately.  The defaults
   are deliberately small:

   | limit                | default | why                                     |
   | -------------------- | ------- | --------------------------------------- |
   | `max-request-line`   | 8 KiB   | a URL longer than this is not a mistake |
   | `max-header-bytes`   | 16 KiB  | bounds the header block alone           |
   | `max-headers`        | 100     | bounds per-header work                  |
   | `max-body`           | 1 MiB   | bounds one request body                 |

   ## Framing

   Framing is where HTTP servers get taken apart, so this parser is strict
   rather than forgiving:

   * line endings must be CRLF -- a bare CR or a bare LF anywhere in the head
     is a 400, because an intermediary that accepts one where we accept the
     other is exactly how requests get smuggled past a front end;
   * `Content-Length` must be one or more ASCII digits and nothing else (no
     sign, no `0x`, no separators), and repeating the header with conflicting
     values is a 400;
   * `Transfer-Encoding` together with `Content-Length` is a 400, and
     `Transfer-Encoding` on its own is a 501.

   ## Not implemented

   Chunked request bodies, compression, multipart, HTTP/2, and anything
   proxy-shaped.  A request that needs them is rejected with a status, not
   half-handled: `Transfer-Encoding` is answered with 501.
*/
module http/message

import bytes/bytes
import strbuilder/strbuilder

pub struct limits
  max-request-line : int
  max-header-bytes : int
  max-headers      : int
  max-body         : int

pub val default-limits : limits
  = Limits(8 * 1024, 16 * 1024, 100, 1024 * 1024)

// ----------------------------------------------------------------------------
// requests
// ----------------------------------------------------------------------------

pub struct request
  method  : string
  // The path with any query string removed.
  path    : string
  query   : string
  version : string
  // Header names are lower-cased on the way in, so lookup is case insensitive
  // without a second pass.
  headers : list<(string, string)>
  body    : bytes

pub fun header( r : request, name : string ) : maybe<string>
  val lname = name.to-lower
  r.headers.lookup(fn(k) k == lname)

fun find-headers( hs : list<(string, string)>, lname : string ) : div list<string>
  hs.filter(fn(kv) kv.fst == lname).map(fn(kv) kv.snd)

// A strict non-negative decimal: one or more ASCII digits and nothing else.
// `parse-int` is deliberately not used -- it accepts `+13`, `0x0d` and `1_3`,
// none of which are legal HTTP field values, and each of them is a framing
// disagreement waiting to happen.
pub fun strict-nat( s : string ) : maybe<int>
  val cs = s.list
  if cs.is-nil then Nothing
  elif cs.any(fn(c) c < '0' || c > '9') then Nothing
  else s.parse-int

// The declared body length, or 0 when the header is absent or unparseable.
// `parse` has already refused anything ambiguous, so by the time a handler sees
// a `:request` the only reason this can be 0 is that the body really is empty.
pub fun content-length( r : request ) : int
  match r.header("content-length")
    Nothing -> 0
    Just(v) -> match v.trim.strict-nat
                 Just(n)  -> n
                 Nothing  -> 0

// Does the client want the connection kept open?  HTTP/1.1 defaults to yes.
pub fun wants-keep-alive( r : request ) : bool
  match r.header("connection")
    Just(v) -> v.to-lower.trim != "close"
    Nothing -> r.version != "HTTP/1.0"

// ----------------------------------------------------------------------------
// responses
// ----------------------------------------------------------------------------

pub struct response
  status  : int
  reason  : string
  headers : list<(string, string)>
  body    : bytes

pub fun response( status : int, body : bytes = bytes-empty,
                  headers : list<(string, string)> = [],
                  reason : string = "" ) : response
  Response(status, if reason.is-empty then default-reason(status) else reason, headers, body)

pub fun text-response( status : int, text : string,
                       content-type : string = "text/plain; charset=utf-8" ) : response
  response(status, bytes(text), [("content-type", content-type)])

pub fun json-response( status : int, json-text : string ) : response
  response(status, bytes(json-text), [("content-type", "application/json")])

pub fun default-reason( status : int ) : string
  match status
    200 -> "OK"
    201 -> "Created"
    204 -> "No Content"
    400 -> "Bad Request"
    404 -> "Not Found"
    405 -> "Method Not Allowed"
    408 -> "Request Timeout"
    409 -> "Conflict"
    413 -> "Payload Too Large"
    414 -> "URI Too Long"
    415 -> "Unsupported Media Type"
    422 -> "Unprocessable Entity"
    431 -> "Request Header Fields Too Large"
    500 -> "Internal Server Error"
    501 -> "Not Implemented"
    503 -> "Service Unavailable"
    _   -> "Unknown"

// Serialise a response.  `Content-Length` is always emitted (never chunked),
// and `Connection` reflects what the server decided rather than what the
// client asked for.
pub fun render( r : response, keep-alive : bool ) : div bytes
  val head = build fn(b)
    val b1 = b.append("HTTP/1.1 ").append-int(r.status).append(" ")
              .append(r.reason.safe-reason)
              .append("\r\n")
              .append("content-length: ").append-int(r.body.length).append("\r\n")
              .append("connection: ").append(if keep-alive then "keep-alive" else "close")
              .append("\r\n")
    r.headers.filter(is-renderable).foldl(b1, render-header).append("\r\n")
  bytes(head) ++ r.body

// Framing is the server's to decide.  A handler that supplied its own
// `content-length`, `transfer-encoding` or `connection` would produce a
// response with two of them, which a client and a proxy may frame
// differently -- so those are dropped, not emitted alongside.
val framing-headers : list<string> = ["content-length", "transfer-encoding", "connection"]

fun is-renderable( h : (string, string) ) : bool
  val k = h.fst.to-lower
  k.is-token && !h.snd.has-control && !framing-headers.any(fn(f) f == k)

fun render-header( b : strbuilder, h : (string, string) ) : strbuilder
  b.append(h.fst).append(": ").append(h.snd).append("\r\n")

// A reason phrase may not carry controls either; an unexpected one is replaced
// wholesale rather than patched, so nothing an attacker chose survives.
fun safe-reason( s : string ) : string
  if s.has-control || s.contains("\r") || s.contains("\n") then "Unknown" else s

// ----------------------------------------------------------------------------
// parsing
// ----------------------------------------------------------------------------

// Why a request was rejected.  Each carries the status to answer with, so the
// server does not have to map errors to codes itself.
pub struct parse-error
  status  : int
  message : string

pub type parse-result
  // Not enough input yet; feed more.
  Incomplete
  Parsed( request : request, rest : bytes )
  Failed( error : parse-error )

// Parse one request out of `buffer`.
//
// Returns `Incomplete` when more input is needed, `Parsed` with whatever
// followed the request (the start of the next one, on a keep-alive
// connection), or `Failed` with the status to answer with.
// `from` is a promise from the caller that no terminator begins before that
// offset, so a connection that arrives one octet at a time costs O(total)
// scanning across all the calls rather than O(total^2).
pub fun parse( buffer : bytes, lim : limits = default-limits, from : int = 0 ) : div parse-result
  match buffer.index-of(bytes("\r\n\r\n"), max(0, from))
    Nothing ->
      // No complete header block yet.  Refuse early if it is already too big
      // rather than buffering without limit.  `+ 4` is the terminator itself.
      if buffer.length > lim.max-header-bytes + lim.max-request-line + 4
        then Failed(Parse-error(431, "header block is too large"))
        else Incomplete
    Just(i) ->
      // `i` is a byte offset, so every size below is in octets.  Counting
      // characters would let a path of multi-byte codepoints run past a limit
      // that is documented in bytes.
      val head-bytes = buffer.take(i)
      val body-start = i + 4
      // No CRLF inside the head means the whole head is the request line.
      val line-end   = match head-bytes.index-of(bytes("\r\n"))
                         Just(j) -> j
                         Nothing -> i
      if line-end > lim.max-request-line then
        Failed(Parse-error(414, "request line is too long"))
      elif i - line-end > lim.max-header-bytes then
        Failed(Parse-error(431, "header block is too large"))
      elif head-bytes.has-bare-eol then
        Failed(Parse-error(400, "a bare CR or LF in the head"))
      else match parse-head(head-bytes.to-string-lossy, lim)
        Left(e) -> Failed(e)
        Right((m, p, q, v, hs)) ->
          match body-length(hs, lim)
            Left(e) -> Failed(e)
            Right(n) ->
              if buffer.length - body-start < n then Incomplete
              else
                val body = buffer.slice(body-start, n)
                Parsed(Request(m, p, q, v, hs, body), buffer.drop(body-start + n))

// True when the head contains a CR that is not followed by LF, or an LF that
// is not preceded by CR.  Either one means this parser and an intermediary may
// disagree about where a header -- and therefore a request -- ends.
fun has-bare-eol( b : bytes ) : div bool
  fun go( i : int ) : div bool
    match b.at(i)
      Nothing  -> False                 // past the end: nothing bare left
      Just(13) -> match b.at(i + 1)     // CR: only legal immediately before LF
                    Just(10) -> go(i + 2)
                    _        -> True
      Just(10) -> True                  // LF with no CR in front of it
      Just(_)  -> go(i + 1)
  go(0)

fun parse-head( head : string, lim : limits )
    : div either<parse-error, (string, string, string, string, list<(string,string)>)>
  val lines = head.split("\r\n")
  match lines
    Nil -> Left(Parse-error(400, "empty request"))
    Cons(reqline, hlines) ->
      // the request line's octet length was already bounded by `parse`
      match reqline.split(" ")
        Cons(m, Cons(target, Cons(v, Nil))) ->
          if !(v.starts-with("HTTP/").bool) then
            Left(Parse-error(400, "malformed HTTP version"))
          elif m.is-empty || !target.starts-with("/").bool then
            Left(Parse-error(400, "malformed request line"))
          else
            val (p, q) = split-target(target)
            match parse-headers(hlines, [], 0, lim)
              Left(e)   -> Left(e)
              Right(hs) -> Right((m, p, q, v, hs))
        _ -> Left(Parse-error(400, "malformed request line"))

fun split-target( target : string ) : div (string, string)
  match target.split("?")
    Cons(p, Cons(q, _)) -> (p, q)
    _ -> (target, "")

fun parse-headers( lines : list<string>, acc : list<(string,string)>, n : int, lim : limits )
    : div either<parse-error, list<(string,string)>>
  match lines
    Nil -> Right(acc.reverse)
    Cons(l, rest) ->
      if l.is-empty then parse-headers(rest, acc, n, lim)
      elif l.starts-with(" ").bool || l.starts-with("\t").bool then
        // obsolete line folding: deprecated by RFC 7230 and a reliable source
        // of front-end/back-end disagreement
        Left(Parse-error(400, "obsolete header line folding"))
      elif n >= lim.max-headers then
        Left(Parse-error(431, "too many headers"))
      else match l.split(":")
        Cons(name, Cons(v, more)) ->
          val value = (Cons(v, more)).join(":").trim
          val key   = name.to-lower
          // No space is allowed between the name and the colon, and the name
          // must be a token -- `Foo : x` and `Foo\x00: x` are both refused.
          if !key.is-token then Left(Parse-error(400, "malformed header name"))
          elif value.has-control then Left(Parse-error(400, "malformed header value"))
          else parse-headers(rest, Cons((key, value), acc), n + 1, lim)
        _ -> Left(Parse-error(400, "malformed header"))

// RFC 9110 `token`: visible ASCII minus the separators.
pub fun is-token( s : string ) : bool
  !s.is-empty && s.list.all(fn(c) is-token-char(c))

val token-punctuation : list<char> = "!#$%&'*+-.^_`|~".list

fun is-token-char( c : char ) : bool
  (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') ||
  token-punctuation.any(fn(t) t == c)

// Any control character other than HTAB has no business in a field value.
pub fun has-control( s : string ) : bool
  s.list.any(fn(c) (c < ' ' && c != '\t') || c == '\x7f')

// Decide how many octets of body follow.
//
// Every `content-length` in the message is considered, not just the first.
// A message carrying two different lengths is one that this server and an
// intermediary would frame differently, and that difference is request
// smuggling -- so it is refused outright rather than resolved.
fun body-length( hs : list<(string,string)>, lim : limits ) : div either<parse-error, int>
  val tes = find-headers(hs, "transfer-encoding")
  val cls = find-headers(hs, "content-length")
  if tes.is-cons && cls.is-cons then
    Left(Parse-error(400, "both transfer-encoding and content-length"))
  elif tes.is-cons then
    Left(Parse-error(501, "chunked transfer encoding is not supported"))
  elif cls.is-nil then Right(0)
  else
    // RFC 9110 permits a single field holding a comma-separated list, but only
    // when every element is identical; the same rule covers repeated fields.
    val vs = cls.flatmap(fn(v) v.split(",")).map(fn(v) v.trim)
    match all-just(vs.map(strict-nat))
      Nothing        -> Left(Parse-error(400, "malformed content-length"))
      Just(Nil)      -> Right(0)
      Just(Cons(n, more)) ->
        if more.any(fn(x) x != n) then
          Left(Parse-error(400, "conflicting content-length"))
        elif n > lim.max-body then Left(Parse-error(413, "body is too large"))
        else Right(n)

// Every value, or `Nothing` if any one is missing.  Written out rather than
// `any(is-nothing)` followed by `default`: the second pass has to invent a
// value for the case the first pass just ruled out, and the invented value is
// indistinguishable from a real one.
fun all-just( xs : list<maybe<a>> ) : div maybe<list<a>>
  match xs
    Nil                 -> Just([])
    Cons(Nothing, _)    -> Nothing
    Cons(Just(x), rest) ->
      match all-just(rest)
        Just(ys) -> Just(Cons(x, ys))
        Nothing  -> Nothing
