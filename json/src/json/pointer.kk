/* RFC 6901 JSON Pointer lookup and construction.

   A pointer is deliberately a separate module from `json/value`: applications
   that only construct and render values do not need pointer parsing in scope.
   This implements the string representation (`/a/0`), not the URI fragment
   representation (`#/a/0`), whose percent decoding belongs at the URI layer.
*/
module json/pointer

import json/value

// Look up `path` in `root`.
//
// The empty pointer names `root`.  Object tokens are matched exactly after
// RFC 6901 unescaping.  Array tokens are canonical non-negative decimal
// indexes: `0` is valid, but `00`, signs and `-` are not.
pub fun pointer( root : json, path : string ) : maybe<json>
  if path.is-empty then Just(root)
  elif !path.starts-with("/").bool then Nothing
  else walk(root, path.split("/").drop(1))

fun walk( current : json, tokens : list<string> ) : maybe<json>
  match tokens
    Nil -> Just(current)
    Cons(encoded, rest) ->
      match decode-token(encoded)
        Nothing -> Nothing
        Just(token) ->
          match current
            JsObject(_) ->
              match current.member(token)
                Just(next) -> walk(next, rest)
                Nothing   -> Nothing
            JsArray(items) ->
              match array-index(token)
                Just(i) ->
                  match nth(items, i)
                    Just(next) -> walk(next, rest)
                    Nothing   -> Nothing
                Nothing -> Nothing
            _ -> Nothing

// Escape one reference token for use in a pointer.
pub fun pointer-token( token : string ) : string
  token.list.map(fn(c)
    if c == '~' then "~0"
    elif c == '/' then "~1"
    else string([c])
  ).join("")

// Build a pointer from unescaped reference tokens.  `[]` names the root.
pub fun pointer-path( tokens : list<string> ) : string
  match tokens
    Nil -> ""
    _   -> "/" ++ tokens.map(pointer-token).join("/")

fun decode-token( token : string ) : maybe<string>
  decode-chars(token.list, [])

fun decode-chars( chars : list<char>, acc : list<char> ) : maybe<string>
  match chars
    Nil -> Just(acc.reverse.string)
    Cons(c, rest) ->
      if c != '~' then decode-chars(rest, Cons(c, acc))
      else match rest
        Cons('0', tail) -> decode-chars(tail, Cons('~', acc))
        Cons('1', tail) -> decode-chars(tail, Cons('/', acc))
        _               -> Nothing

fun array-index( token : string ) : maybe<int>
  if token.is-empty then Nothing
  elif token != "0" && token.starts-with("0").bool then Nothing
  elif !token.list.all(fn(c) c >= '0' && c <= '9') then Nothing
  else token.parse-int

fun nth( items : list<a>, index : int ) : maybe<a>
  if index < 0 then Nothing
  else match items
    Nil -> Nothing
    Cons(x, rest) -> if index == 0 then Just(x) else nth(rest, index - 1)
