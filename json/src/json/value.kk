/* The JSON value type.

   Objects keep their members in source order in an association list rather
   than a map.  That is deliberate: a service that echoes a document back
   should not reorder it, output stays deterministic, and the documents this
   program handles are small enough that linear lookup is not the bottleneck.
   Use `hashmap` explicitly if a large object needs indexed access.
*/
module json/value

import strbuilder/strbuilder

pub type json
  JsNull
  JsBool( value : bool )
  // JSON has one number type.  It is kept as an `:int` here because every
  // value the reference service exchanges is integral, and an integer round
  // trips exactly where a float would not.  Fractional input is rejected by
  // the parser with a clear message rather than silently truncated.
  JsInt( value : int )
  JsString( value : string )
  JsArray( items : list<json> )
  JsObject( members : list<(string, json)> )

// ----------------------------------------------------------------------------
// accessors
//
// Every accessor returns `:maybe` rather than throwing, so a decoder can
// report all of a document's problems in its own terms.
// ----------------------------------------------------------------------------

pub fun member( j : json, name : string ) : maybe<json>
  match j
    JsObject(ms) -> ms.lookup(fn(k) k == name)
    _            -> Nothing

pub fun as-string( j : json ) : maybe<string>
  match j
    JsString(s) -> Just(s)
    _           -> Nothing

pub fun as-int( j : json ) : maybe<int>
  match j
    JsInt(i) -> Just(i)
    _        -> Nothing

pub fun as-bool( j : json ) : maybe<bool>
  match j
    JsBool(b) -> Just(b)
    _         -> Nothing

pub fun as-array( j : json ) : maybe<list<json>>
  match j
    JsArray(xs) -> Just(xs)
    _           -> Nothing

pub fun as-object( j : json ) : maybe<list<(string, json)>>
  match j
    JsObject(ms) -> Just(ms)
    _            -> Nothing

pub fun is-null( j : json ) : bool
  match j
    JsNull -> True
    _      -> False

// A short description of the shape, for error messages.
pub fun type-name( j : json ) : string
  match j
    JsNull      -> "null"
    JsBool(_)   -> "a boolean"
    JsInt(_)    -> "a number"
    JsString(_) -> "a string"
    JsArray(_)  -> "an array"
    JsObject(_) -> "an object"

// ----------------------------------------------------------------------------
// generation
//
// Output is deterministic: members are emitted in the order they appear in the
// value, arrays in order, and nothing is sorted or reordered.  Escaping is the
// builder's, which follows RFC 8259.
//
// Generation is builder based, so a large document costs one buffer rather
// than a chain of concatenations.
// ----------------------------------------------------------------------------

pub fun write( b : strbuilder, j : json ) : div strbuilder
  match j
    JsNull      -> b.append("null")
    JsBool(v)   -> b.append(if v then "true" else "false")
    JsInt(v)    -> b.append-int(v)
    JsString(s) -> b.append-json-string(s)
    JsArray(xs) -> write-array(b.append("["), xs, True).append("]")
    JsObject(ms)-> write-object(b.append("{"), ms, True).append("}")

fun write-array( b : strbuilder, xs : list<json>, first : bool ) : div strbuilder
  match xs
    Nil -> b
    Cons(x, rest) ->
      val b1 = if first then b else b.append(",")
      write-array(b1.write(x), rest, False)

fun write-object( b : strbuilder, ms : list<(string, json)>, first : bool ) : div strbuilder
  match ms
    Nil -> b
    Cons((k, v), rest) ->
      val b1 = if first then b else b.append(",")
      write-object(b1.append-json-string(k).append(":").write(v), rest, False)

// Render to a string.
pub fun show( j : json ) : div string
  build(fn(b) b.write(j))

// ----------------------------------------------------------------------------
// construction helpers
// ----------------------------------------------------------------------------

pub fun obj( members : list<(string, json)> ) : json
  JsObject(members)

pub fun arr( items : list<json> ) : json
  JsArray(items)

pub fun str( s : string ) : json
  JsString(s)

pub fun num( i : int ) : json
  JsInt(i)

pub fun boolean( b : bool ) : json
  JsBool(b)
