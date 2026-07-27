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
      // Unescaped characters are appended a run at a time, so the boundaries
      // of a run are what can go wrong: an escape first, last, alone, and two
      // in a row must not drop or reorder the text around them.
      test("runs around the escapes come out in order", fn()
        assert-equal(build(fn(b) b.append-json-escaped("\"abc")), "\\\"abc")
        assert-equal(build(fn(b) b.append-json-escaped("abc\"")), "abc\\\"")
        assert-equal(build(fn(b) b.append-json-escaped("\t\n")), "\\t\\n")
        assert-equal(build(fn(b) b.append-json-escaped("")), "")
        assert-equal(build(fn(b) b.append-json-escaped("a\tb\nc")), "a\\tb\\nc")
        assert-equal(build(fn(b) b.append-json-escaped("é\té")), "é\\té")
      ),
      test("append-json-string adds the quotes", fn()
        assert-equal(build(fn(b) b.append-json-string("a\"b")), "\"a\\\"b\"")
        assert-equal(build(fn(b) b.append-json-string("")), "\"\"")
      ),
    ]),

    group("append complexity", [
      // Growth, not wall clock.  The naive `s := s ++ chunk` alternative runs
      // 20000 appends in about 95 ms here, so a 5-second absolute threshold
      // left a ~50x margin over the very behaviour it claimed to catch -- it
      // passed at either complexity.  Comparing n against 4n does not:
      // O(n) predicts ~4x, O(n^2) predicts ~16x.
      test("appending is O(n) in the total length", fn()
        fun timed( n : int )
          val t0 = mono-ms()
          var b := strbuilder()
          var i := 0
          while { i < n }
            b := b.append("0123456789")
            i := i + 1
          assert-equal(b.finish.count, n * 10)
          mono-ms() - t0
        // a floor absorbs timer noise at the small end
        val t1 = max(timed(20000), 4)
        val t4 = timed(80000)
        assert-true(t4 < t1 * 8,
                    "4x the work took " ++ t4.show ++ "ms against " ++ t1.show ++
                    "ms for n; O(n) should be about 4x, O(n^2) about 16x")
      , timeout-s = 60),
    ]),

    group("properties", [
      test("appending equals concatenating", fn()
        check(gen-list(gen-string()), concat-matches)
      ),
      // gen-text, not gen-string: the default alphabet contains no quote, no
      // backslash and no control character, so this property used to check
      // that the identity function is invertible.
      test("escaping is reversible", fn()
        check(gen-text(), escaping-round-trips)
      ),
    ]),
  ])
