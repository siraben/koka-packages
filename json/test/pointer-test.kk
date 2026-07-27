import kktest/assert
import kktest/runner
import json/value
import json/pointer

val document : json
  = obj([ ("name", str("koka"))
        , ("items", arr([obj([("id", num(10))]), obj([("id", num(20))])]))
        , ("a/b", str("slash"))
        , ("m~n", str("tilde"))
        , ("", str("empty"))
        ])

fun selected( path : string ) : maybe<json>
  document.pointer(path)

fun selected-string( path : string ) : maybe<string>
  match selected(path)
    Just(v) -> v.as-string
    Nothing -> Nothing

fun selected-int( path : string ) : maybe<int>
  match selected(path)
    Just(v) -> v.as-int
    Nothing -> Nothing

fun main()
  run-tests([
    group("lookup", [
      test("the empty pointer selects the root", fn()
        assert-equal(selected("").map(type-name), Just("an object"))
      ),
      test("object members and array indexes compose", fn()
        assert-equal(selected-string("/name"), Just("koka"))
        assert-equal(selected-int("/items/0/id"), Just(10))
        assert-equal(selected-int("/items/1/id"), Just(20))
      ),
      test("escaped slash and tilde tokens decode", fn()
        assert-equal(selected-string("/a~1b"), Just("slash"))
        assert-equal(selected-string("/m~0n"), Just("tilde"))
      ),
      test("an empty token addresses an empty object key", fn()
        assert-equal(selected-string("/"), Just("empty"))
      ),
      test("missing paths return Nothing", fn()
        assert-true(selected("/missing").is-nothing)
        assert-true(selected("/items/4").is-nothing)
        assert-true(selected("/name/child").is-nothing)
      ),
    ]),

    group("strict syntax", [
      test("a non-empty pointer starts with slash", fn()
        assert-true(selected("name").is-nothing)
      ),
      test("invalid escape sequences are rejected", fn()
        assert-true(selected("/m~2n").is-nothing)
        assert-true(selected("/m~").is-nothing)
      ),
      test("array indexes are canonical non-negative decimals", fn()
        assert-true(selected("/items/00").is-nothing)
        assert-true(selected("/items/+1").is-nothing)
        assert-true(selected("/items/-").is-nothing)
        assert-true(selected("/items/one").is-nothing)
      ),
    ]),

    group("construction", [
      test("tokens are escaped in the RFC-mandated order", fn()
        assert-equal(pointer-token("a~/b"), "a~0~1b")
        assert-equal(pointer-path(["a/b", "m~n"]), "/a~1b/m~0n")
      ),
      test("built pointers round-trip through lookup", fn()
        assert-equal(selected-string(pointer-path(["a/b"])), Just("slash"))
        assert-equal(pointer-path([]), "")
      ),
    ]),
  ])
