import kktest/assert
import kktest/runner
import kktest/prop
import bytes/bytes

// Explicit renderers: `.show` on a `maybe` is ambiguous once several `show`
// instances are in scope, and a test should say which one it means.
fun mi( m : maybe<int> ) : string
  match m
    Just(x) -> "Just(" ++ x.show ++ ")"
    Nothing -> "Nothing"

fun ms( m : maybe<string> ) : string
  match m
    Just(x) -> "Just(" ++ x.show ++ ")"
    Nothing -> "Nothing"

fun ord( o : order ) : string
  match o
    Lt -> "Lt"
    Eq -> "Eq"
    Gt -> "Gt"

fun bs( xs : list<int> ) : bytes
  bytes(xs)

fun octets( b : bytes ) : string
  b.list.show

fun split-rejoins( p : (string, int) ) : bool
  val b = bytes(p.fst)
  (b.take(p.snd) ++ b.drop(p.snd)) == b

fun builder-matches-concat( ss : list<string> ) : bool
  val built = ss.foldl(builder-empty(), fn(acc, s) acc.snoc-string(s)).finish
  built == concat(ss.map(bytes))

fun main()
  run-tests([
    group("construction", [
      test("empty", fn()
        assert-equal(bytes-empty.length, 0)
        assert-true(bytes-empty.is-empty)
      ),
      test("from a string is its utf-8 encoding", fn()
        assert-equal(bytes("abc").length, 3)
        assert-equal(bytes("é").length, 2)      // U+00E9 is two octets
      ),
      test("from a list of octets", fn()
        assert-equal(bs([1,2,3]).length, 3)
        assert-equal(bs([1,2,3]).octets, [1,2,3].show)
      ),
      test("octet values wrap at 256", fn()
        assert-equal(bs([256, 257]).octets, [0,1].show)
      ),
      test("replicate", fn()
        assert-equal(bytes/replicate(7, 4).octets, [7,7,7,7].show)
        assert-equal(bytes/replicate(7, 0).length, 0)
      ),
    ]),

    group("indexing", [
      test("in range", fn()
        assert-equal(mi(bs([10,20,30]).at(1)), "Just(20)")
      ),
      test("out of range is Nothing, not a crash", fn()
        assert-equal(mi(bs([10]).at(-1)), "Nothing")
        assert-equal(mi(bs([10]).at(1)), "Nothing")
        assert-equal(mi(bytes-empty.at(0)), "Nothing")
      ),
      // `at` hands the index to C, where it is clamped to a machine word: an
      // index far beyond one must not wrap around into range.
      test("an index too big for a machine word is Nothing, not a wrap", fn()
        assert-equal(mi(bs([10,20,30]).at(1180591620717411303424)), "Nothing")
        assert-equal(mi(bs([10,20,30]).at(-1180591620717411303424)), "Nothing")
      ),
      test("at-exn throws out of range", fn()
        assert-throws({ bs([10]).at-exn(5) }, containing = "out of range")
      ),
    ]),

    group("slicing", [
      test("basic", fn()
        val b = bs([0,1,2,3,4])
        assert-equal(b.slice(1, 3).octets, [1,2,3].show)
        assert-equal(b.take(2).octets, [0,1].show)
        assert-equal(b.drop(3).octets, [3,4].show)
      ),
      test("clamps instead of failing", fn()
        val b = bs([0,1,2])
        assert-equal(b.slice(-5, 100).octets, [0,1,2].show)
        assert-equal(b.slice(10, 5).length, 0)
        assert-equal(b.take(100).length, 3)
        assert-equal(b.drop(100).length, 0)
      ),
    ]),

    group("concatenation", [
      test("cat", fn()
        assert-equal((bs([1,2]) ++ bs([3])).octets, [1,2,3].show)
        assert-equal((bytes-empty ++ bs([1])).octets, [1].show)
        assert-equal((bs([1]) ++ bytes-empty).octets, [1].show)
      ),
      test("concat of a list", fn()
        assert-equal(concat([bs([1]), bs([2,3]), bytes-empty]).octets, [1,2,3].show)
        assert-equal(bytes/concat([]).length, 0)
      ),
    ]),

    group("searching", [
      test("index-of", fn()
        val b = bytes("hello world")
        assert-equal(mi(b.index-of(bytes("world"))), "Just(6)")
        assert-equal(mi(b.index-of(bytes("zzz"))), "Nothing")
        assert-equal(mi(b.index-of(bytes("o"), 5)), "Just(7)")
      ),
      // The scan skips ahead with `memchr` and rejects a candidate on its last
      // octet, so the cases that exercise those: a needle whose first octet
      // repeats, a match at the very end, a one-octet needle, an empty needle,
      // and a starting point past the end.
      test("index-of over repeated and boundary needles", fn()
        val b = bytes("aaaaab")
        assert-equal(mi(b.index-of(bytes("aaab"))), "Just(2)")
        assert-equal(mi(b.index-of(bytes("aaac"))), "Nothing")
        assert-equal(mi(b.index-of(bytes("ab"))), "Just(4)")
        assert-equal(mi(b.index-of(bytes("b"))), "Just(5)")
        assert-equal(mi(b.index-of(bytes("aaaaab"))), "Just(0)")
        assert-equal(mi(b.index-of(bytes("aaaaabb"))), "Nothing")
        assert-equal(mi(b.index-of(bytes("a"), 4)), "Just(4)")
        assert-equal(mi(b.index-of(bytes("a"), 5)), "Nothing")
        assert-equal(mi(b.index-of(bytes-empty, 3)), "Just(3)")
        assert-equal(mi(b.index-of(bytes-empty, 99)), "Nothing")
        assert-equal(mi(b.index-of(bytes("a"), 99)), "Nothing")
        assert-equal(mi(bytes-empty.index-of(bytes("a"))), "Nothing")
      ),
      test("starts-with", fn()
        assert-true(bytes("hello").starts-with(bytes("hel")))
        assert-false(bytes("hello").starts-with(bytes("world")))
        assert-true(bytes("hello").starts-with(bytes-empty))
        assert-false(bytes("he").starts-with(bytes("hello")))
      ),
      test("split", fn()
        val parts = bytes("a,b,,c").split(44)   // ','
        assert-equal(parts.length, 4)
        assert-equal(parts.map(to-string-lossy).show, ["a","b","","c"].show)
      ),
      test("split with no separator yields one part", fn()
        assert-equal(bytes("abc").split(44).length, 1)
        assert-equal(bytes-empty.split(44).length, 1)
      ),
    ]),

    group("text conversion", [
      test("round trips valid utf-8", fn()
        assert-equal(ms(bytes("hello é世").to-string), ms(Just("hello é世")))
      ),
      test("rejects invalid utf-8", fn()
        assert-equal(ms(bs([0x80]).to-string), "Nothing")               // lone continuation
        assert-equal(ms(bs([0xC3]).to-string), "Nothing")               // truncated
        assert-equal(ms(bs([0xC0, 0xAF]).to-string), "Nothing")         // overlong '/'
        assert-equal(ms(bs([0xED, 0xA0, 0x80]).to-string), "Nothing")   // surrogate
        assert-equal(ms(bs([0xF5, 0x80, 0x80, 0x80]).to-string), "Nothing") // above U+10FFFF
      ),
      test("embedded NUL is an ordinary octet", fn()
        val b = bs([97, 0, 98])
        assert-equal(b.length, 3)
        assert-true(b.to-string.is-just)
      ),
      test("lossy decoding replaces invalid sequences", fn()
        val s = bs([97, 0x80, 98]).to-string-lossy
        assert-true(s.contains("a"))
        assert-true(s.contains("b"))
      ),
      test("hex", fn()
        assert-equal(bs([0, 15, 255]).to-hex, "000fff")
        assert-equal(bytes-empty.to-hex, "")
      ),
    ]),

    group("equality, ordering, hashing", [
      test("equality is by content", fn()
        assert-true(bs([1,2]) == bs([1,2]))
        assert-true(bs([1,2]) != bs([1,3]))
        assert-true(bs([1,2]) != bs([1,2,3]))
        assert-true(bytes-empty == bytes-empty)
      ),
      test("ordering is lexicographic, shorter first on a prefix", fn()
        assert-equal(ord(bytes/compare(bs([1,2]), bs([1,3]))), "Lt")
        assert-equal(ord(bytes/compare(bs([1,2]), bs([1,2]))), "Eq")
        assert-equal(ord(bytes/compare(bs([1,2]), bs([1]))), "Gt")
      ),
      test("equal values hash equally", fn()
        // built two different ways, so the assertion can actually fail
        assert-equal(bytes("hello").hash, bs([104,101,108,108,111]).hash)
        assert-equal((bs([1]) ++ bs([2])).hash, bs([1,2]).hash)
        assert-true(bytes-empty.hash >= 0)
        // the high-octet case the ASCII generator can never reach
        assert-true(bs([255,255,255,255,255,255,255,255]).hash >= 0)
      ),
      test("hash is never negative", fn()
        check(gen-string(), fn(s) bytes(s).hash >= 0)
      ),
    ]),

    group("integer encoding", [
      test("big endian round trip", fn()
        assert-equal(mi(be16(0x1234).read-be16), "Just(4660)")
        assert-equal(mi(be32(0x12345678).read-be32), "Just(305419896)")
        assert-equal(mi(be16(0).read-be16), "Just(0)")
        assert-equal(mi(be16(65535).read-be16), "Just(65535)")
      ),
      test("little endian round trip", fn()
        assert-equal(mi(le16(0x1234).read-le16), "Just(4660)")
        assert-equal(mi(le32(0x12345678).read-le32), "Just(305419896)")
      ),
      test("endianness really differs", fn()
        assert-equal(be16(0x0102).octets, [1,2].show)
        assert-equal(le16(0x0102).octets, [2,1].show)
      ),
      test("bounded reads do not run off the end", fn()
        assert-equal(mi(bs([1]).read-be16), "Nothing")
        assert-equal(mi(bs([1,2,3]).read-be32), "Nothing")
        assert-equal(mi(bytes-empty.read-be16), "Nothing")
      ),
    ]),

    group("builder", [
      test("appends", fn()
        val b = builder-empty().snoc-byte(1).snoc(bs([2,3])).snoc-string("A")
        assert-equal(b.length, 4)
        assert-equal(b.finish.octets, [1,2,3,65].show)
      ),
      test("finish leaves the builder reusable and empty", fn()
        val b = builder-empty().snoc-byte(1)
        assert-equal(b.finish.octets, [1].show)
        assert-equal(b.length, 0)
        assert-equal(b.snoc-byte(2).finish.octets, [2].show)
      ),
      test("reserve does not change the contents", fn()
        val b = builder-empty(1).snoc-byte(7).reserve(1000).snoc-byte(8)
        assert-equal(b.finish.octets, [7,8].show)
      ),
      test("many appends stay correct across growth", fn()
        var b := builder-empty(1)
        var i := 0
        while { i < 5000 }
          b := b.snoc-byte(i % 256)
          i := i + 1
        val out = b.finish
        assert-equal(out.length, 5000)
        assert-equal(mi(out.at(0)), "Just(0)")
        assert-equal(mi(out.at(4999)), mi(Just(4999 % 256)))
      ),
    ]),

    group("properties", [
      test("round trips through a string", fn()
        check(gen-string(), fn(s) bytes(s).to-string == Just(s))
      ),
      test("length of a concatenation is the sum", fn()
        check(gen-pair(gen-string(), gen-string()),
              fn(p) (bytes(p.fst) ++ bytes(p.snd)).length ==
                    bytes(p.fst).length + bytes(p.snd).length)
      ),
      test("take n ++ drop n is the original", fn()
        check(gen-pair(gen-string(), gen-nat(50)), split-rejoins)
      ),
      test("equality agrees with string equality", fn()
        check(gen-pair(gen-string(), gen-string()),
              fn(p) (bytes(p.fst) == bytes(p.snd)) == (p.fst == p.snd))
      ),
      test("a builder equals the concatenation it was fed", fn()
        check(gen-list(gen-string()), builder-matches-concat)
      ),
    ]),
  ])
