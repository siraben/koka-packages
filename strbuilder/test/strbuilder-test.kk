import kktest/assert
import kktest/runner
import kktest/prop
import kktest/sys
import strbuilder/strbuilder
import bytes/bytes

fun concat-matches( parts : list<string> ) : div bool
  val built = parts.foldl(strbuilder(), fn(b, s) b.append(s)).finish
  built == parts.join("")

fun escaping-round-trips( s : string ) : div bool
  // escaping then unescaping the escapes this module produces is the identity
  val esc = strbuilder().append-json-escaped(s).finish
  unescape(esc) == s

fun unescape( s : string ) : div string
  unesc(s.list, [])

fun unesc( cs : list<char>, acc : list<char> ) : div string
  match cs
    Nil -> acc.reverse.string
    Cons('\\', Cons(c, rest)) ->
      match c
        'n'  -> unesc(rest, Cons('\n', acc))
        'r'  -> unesc(rest, Cons('\r', acc))
        't'  -> unesc(rest, Cons('\t', acc))
        'b'  -> unesc(rest, Cons(char(8), acc))
        'f'  -> unesc(rest, Cons(char(12), acc))
        '"'  -> unesc(rest, Cons('"', acc))
        '\\' -> unesc(rest, Cons('\\', acc))
        'u'  ->
          match rest
            Cons(a, Cons(b2, Cons(c2, Cons(d, more)))) ->
              unesc(more, Cons(char(hexval(a)*4096 + hexval(b2)*256 + hexval(c2)*16 + hexval(d)), acc))
            _ -> acc.reverse.string
        _    -> unesc(rest, Cons(c, acc))
    Cons(c, rest) -> unesc(rest, Cons(c, acc))

fun hexval( c : char ) : int
  val n = c.int
  if n >= 48 && n <= 57 then n - 48
  elif n >= 97 && n <= 102 then n - 87
  elif n >= 65 && n <= 70 then n - 55
  else 0

fun main()
  run-tests([
    group("appending", [
      test("empty", fn()
        assert-equal(strbuilder().finish, "")
        assert-true(strbuilder().is-empty)
      ),
      test("strings, chars and ints", fn()
        val s = strbuilder().append("a").append-char('b').append-int(42).finish
        assert-equal(s, "ab42")
      ),
      test("lines", fn()
        assert-equal(strbuilder().append-line("a").append-line("b").finish, "a\nb\n")
      ),
      test("join", fn()
        assert-equal(strbuilder().append-join(["a","b","c"], ",").finish, "a,b,c")
        assert-equal(strbuilder().append-join([], ",").finish, "")
        assert-equal(strbuilder().append-join(["a"], ",").finish, "a")
      ),
      test("length counts octets", fn()
        assert-equal(strbuilder().append("abc").length, 3)
        assert-equal(strbuilder().append("é").length, 2)
      ),
      test("finish leaves the builder reusable", fn()
        val b = strbuilder().append("x")
        assert-equal(b.finish, "x")
        assert-equal(b.length, 0)
        assert-equal(b.append("y").finish, "y")
      ),
      test("bytes pass through unchanged", fn()
        val b = strbuilder().append("a").append-bytes(bytes("bc"))
        assert-equal(b.finish, "abc")
      ),
      test("finish-bytes avoids the decode", fn()
        assert-true(strbuilder().append("hé").finish-bytes == bytes("hé"))
      ),
      test("build helper", fn()
        assert-equal(build(fn(b) b.append("a").append("b")), "ab")
      ),
    ]),

    group("json escaping", [
      test("mandatory escapes", fn()
        assert-equal(build(fn(b) b.append-json-escaped("a\"b")), "a\\\"b")
        assert-equal(build(fn(b) b.append-json-escaped("a\\b")), "a\\\\b")
      ),
      test("short control escapes", fn()
        assert-equal(build(fn(b) b.append-json-escaped("\n\r\t")), "\\n\\r\\t")
      ),
      test("other control characters use \\u", fn()
        assert-equal(build(fn(b) b.append-json-escaped(char(1).string)), "\\u0001")
        assert-equal(build(fn(b) b.append-json-escaped(char(31).string)), "\\u001f")
      ),
      test("non-ascii is emitted as utf-8, not escaped", fn()
        assert-equal(build(fn(b) b.append-json-escaped("é世")), "é世")
      ),
      test("forward slash is not escaped", fn()
        assert-equal(build(fn(b) b.append-json-escaped("a/b")), "a/b")
      ),
      test("append-json-string adds the quotes", fn()
        assert-equal(build(fn(b) b.append-json-string("a\"b")), "\"a\\\"b\"")
        assert-equal(build(fn(b) b.append-json-string("")), "\"\"")
      ),
    ]),

    group("no quadratic blowup", [
      // 20k appends must be fast; a quadratic builder would take minutes
      test("20000 appends complete quickly", fn()
        val t0 = mono-ms()
        var b := strbuilder()
        var i := 0
        while { i < 20000 }
          b := b.append("0123456789")
          i := i + 1
        val s = b.finish
        val elapsed = mono-ms() - t0
        assert-equal(s.count, 200000)
        assert-true(elapsed < 5000, "took " ++ elapsed.show ++ "ms, expected well under 5s")
      , timeout-s = 30),
    ]),

    group("properties", [
      test("appending equals concatenating", fn()
        check(gen-list(gen-string()), concat-matches)
      ),
      test("escaping is reversible", fn()
        check(gen-string(), escaping-round-trips)
      ),
    ]),
  ])
