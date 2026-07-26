import kktest/assert
import kktest/runner
import kktest/prop
import json/value
import json/parse
import bytes/bytes
import strbuilder/strbuilder

// Parse and render, so a test can state a round trip in one string.
fun rt( s : string ) : div string
  match parse-string(s)
    Right(j) -> j.show
    Left(e)  -> "ERROR: " ++ e.show

fun parse-error( s : string, lim : limits = default-limits ) : div string
  match parse-string(s, lim)
    Right(_) -> "no error"
    Left(e)  -> e.message

fun ok( s : string, lim : limits = default-limits ) : div bool
  match parse-string(s, lim)
    Right(_) -> True
    Left(_)  -> False

// Rendering a value and parsing it back must give the same value.
fun render-parse-round-trips( xs : list<int> ) : div bool
  val v = JsObject([("items", JsArray(xs.map(JsInt))), ("n", JsInt(xs.length))])
  match parse-string(v.show)
    Right(j) -> j.show == v.show
    Left(_)  -> False

fun string-round-trips( s : string ) : div bool
  match parse-string(JsString(s).show)
    Right(JsString(s2)) -> s2 == s
    _                   -> False

fun deep( n : int ) : div string
  // n nested arrays
  build(fn(b) b.append(list(1, n).map(fn(_i) "[").join("")).append(list(1, n).map(fn(_i) "]").join("")))

fun main()
  run-tests([
    group("scalars", [
      test("literals", fn()
        assert-equal(rt("null"), "null")
        assert-equal(rt("true"), "true")
        assert-equal(rt("false"), "false")
      ),
      test("integers", fn()
        assert-equal(rt("0"), "0")
        assert-equal(rt("42"), "42")
        assert-equal(rt("-7"), "-7")
        assert-equal(rt("1234567890123456789012345"), "1234567890123456789012345")
      ),
      test("fractional numbers are rejected, not truncated", fn()
        assert-true(parse-error("1.5").contains("fractional"))
        assert-true(parse-error("1e3").contains("exponent"))
        assert-true(parse-error("1E3").contains("exponent"))
      ),
      test("malformed numbers", fn()
        assert-true(parse-error("-").contains("digit"))
        assert-true(parse-error("+1").contains("unexpected"))
      ),
      test("strings", fn()
        assert-equal(rt("\"\""), "\"\"")
        assert-equal(rt("\"abc\""), "\"abc\"")
      ),
    ]),

    group("string escapes", [
      test("standard escapes", fn()
        assert-equal(rt("\"a\\nb\""), "\"a\\nb\"")
        assert-equal(rt("\"a\\tb\""), "\"a\\tb\"")
        assert-equal(rt("\"a\\\"b\""), "\"a\\\"b\"")
        assert-equal(rt("\"a\\\\b\""), "\"a\\\\b\"")
        assert-equal(rt("\"a\\/b\""), "\"a/b\"")     // escaped slash is optional on output
      ),
      test("unicode escapes", fn()
        assert-equal(rt("\"\\u0041\""), "\"A\"")
        assert-equal(rt("\"\\u00e9\""), "\"é\"")
      ),
      test("surrogate pairs decode to one character", fn()
        // U+1F600
        assert-equal(rt("\"\\ud83d\\ude00\""), "\"😀\"")
      ),
      test("unpaired surrogates are rejected", fn()
        assert-true(parse-error("\"\\ud83d\"").contains("surrogate"))
        assert-true(parse-error("\"\\ude00\"").contains("surrogate"))
        assert-true(parse-error("\"\\ud83dx\"").contains("surrogate"))
      ),
      test("bad escapes", fn()
        assert-true(parse-error("\"\\q\"").contains("unknown escape"))
        assert-true(parse-error("\"\\u00\"").contains("hexadecimal"))
      ),
      test("raw control characters are rejected", fn()
        assert-true(parse-error("\"a\nb\"").contains("control"))
      ),
      test("unterminated strings", fn()
        assert-true(parse-error("\"abc").contains("unterminated"))
      ),
    ]),

    group("arrays and objects", [
      test("arrays", fn()
        assert-equal(rt("[]"), "[]")
        assert-equal(rt("[1,2,3]"), "[1,2,3]")
        assert-equal(rt("[ 1 , 2 ]"), "[1,2]")
        assert-equal(rt("[[1],[2]]"), "[[1],[2]]")
      ),
      test("objects", fn()
        assert-equal(rt("{}"), "{}")
        assert-equal(rt("{\"a\":1}"), "{\"a\":1}")
        assert-equal(rt("{ \"a\" : 1 , \"b\" : 2 }"), "{\"a\":1,\"b\":2}")
      ),
      test("member order is preserved", fn()
        assert-equal(rt("{\"z\":1,\"a\":2,\"m\":3}"), "{\"z\":1,\"a\":2,\"m\":3}")
      ),
      test("mixed nesting", fn()
        assert-equal(rt("{\"a\":[1,{\"b\":null}]}"), "{\"a\":[1,{\"b\":null}]}")
      ),
      test("malformed structure", fn()
        assert-true(parse-error("[1,").contains("unexpected end"))
        assert-true(parse-error("[1 2]").contains("',' or ']'"))
        assert-true(parse-error("{\"a\" 1}").contains("':'"))
        assert-true(parse-error("{a:1}").contains("string key"))
        assert-true(parse-error("{\"a\":1,}").contains("string key"))
      ),
      test("trailing input is rejected", fn()
        assert-true(parse-error("{} {}").contains("trailing"))
        assert-true(parse-error("1 2").contains("trailing"))
      ),
      test("whitespace only", fn()
        assert-true(parse-error("   ").contains("unexpected end"))
        assert-true(parse-error("").contains("unexpected end"))
      ),
    ]),

    group("duplicate keys", [
      test("rejected by default", fn()
        assert-true(parse-error("{\"a\":1,\"a\":2}").contains("duplicate key"))
      ),
      test("first wins when asked", fn()
        val lim = default-limits(duplicates = DuplicateFirst)
        match parse-string("{\"a\":1,\"a\":2}", lim)
          Right(j) -> assert-equal(j.show, "{\"a\":1}")
          Left(e)  -> assert-fail(e.show)
      ),
      test("last wins when asked", fn()
        val lim = default-limits(duplicates = DuplicateLast)
        match parse-string("{\"a\":1,\"a\":2}", lim)
          Right(j) -> assert-equal(j.show, "{\"a\":2}")
          Left(e)  -> assert-fail(e.show)
      ),
    ]),

    group("limits", [
      test("document size", fn()
        val lim = default-limits(max-bytes = 5)
        assert-true(parse-error("[1,2,3,4,5]", lim).contains("larger than"))
      ),
      test("nesting depth", fn()
        // the boundary, against the configured limit -- `ok(deep(4))` with the
        // default 64 said nothing at all about max-depth = 5
        val lim = default-limits(max-depth = 5)
        assert-true(ok(deep(5), lim), "depth 5 should be within max-depth = 5")
        assert-false(ok(deep(6), lim), "depth 6 should exceed max-depth = 5")
        assert-true(ok(deep(64)), "the default limit of 64 should permit 64 levels")
        assert-false(ok(deep(65)), "the default limit of 64 should refuse 65")
        assert-true(parse-error(deep(50), lim).contains("nesting deeper"))
      ),
      test("nesting depth protects against a deliberately deep document", fn()
        // 10000 levels must be rejected, not overflow the stack
        assert-true(parse-error(deep(10000)).contains("nesting deeper"))
      , timeout-s = 30),
      test("member count", fn()
        val lim = default-limits(max-members = 3)
        assert-true(parse-error("[1,2,3,4,5]", lim).contains("more than the limit"))
      ),
      test("string length", fn()
        val lim = default-limits(max-string = 4)
        assert-true(parse-error("\"abcdefgh\"", lim).contains("longer than"))
      ),
    ]),

    group("utf-8", [
      test("valid multi-byte content passes through", fn()
        assert-equal(rt("\"héllo 世界\""), "\"héllo 世界\"")
      ),
      test("invalid utf-8 is rejected", fn()
        match parse(bytes([0x22, 0xC3, 0x22]))     // "\xC3"
          Left(e) -> assert-true(e.message.contains("UTF-8"))
          Right(_) -> assert-fail("expected invalid UTF-8 to be rejected")
      ),
    ]),

    group("error positions", [
      test("line and column point at the problem", fn()
        match parse-string("{\n  \"a\": ,\n}")
          Left(e) ->
            assert-equal(e.line, 2)
            assert-true(e.column > 5, "column was " ++ e.column.show)
          Right(_) -> assert-fail("expected an error")
      ),
      test("offset is a byte offset", fn()
        match parse-string("[1,x]")
          Left(e) -> assert-equal(e.offset, 3)
          Right(_) -> assert-fail("expected an error")
      ),
    ]),

    group("generation", [
      test("escaping is applied to keys and values", fn()
        val v = JsObject([("a\"b", JsString("c\nd"))])
        assert-equal(v.show, "{\"a\\\"b\":\"c\\nd\"}")
      ),
      test("output is deterministic", fn()
        val v = JsObject([("b", JsInt(1)), ("a", JsInt(2))])
        assert-equal(v.show, "{\"b\":1,\"a\":2}")
      ),
      test("accessors", fn()
        val v = JsObject([("n", JsInt(1)), ("s", JsString("x"))])
        assert-equal(v.member("n").map(fn(x) x.show).default("-"), "1")
        assert-equal(v.member("missing").map(fn(x) x.show).default("-"), "-")
        assert-equal(JsInt(5).as-int.default(0), 5)
        assert-equal(JsString("q").as-string.default(""), "q")
        assert-true(JsNull.is-null)
        assert-equal(JsArray([]).type-name, "an array")
      ),
    ]),

    group("properties", [
      test("render then parse is the identity", fn()
        check(gen-list(gen-int(-1000, 1000)), render-parse-round-trips)
      ),
      test("strings survive escaping and unescaping", fn()
        check(gen-text(), string-round-trips)
      ),
    ]),
  ])
