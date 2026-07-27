import kktest/assert
import kktest/runner
import logging/log

fun sink() : io ref<global, list<string>>
  ref([])

fun lines( r : ref<global, list<string>> ) : io list<string>
  (!r).reverse

fun add( r : ref<global, list<string>>, s : string ) : io ()
  r := Cons(s, !r)

// A pinned clock, so a whole log line can be compared.
fun fixed() : <io|e> int
  1700000000000

fun capture( action : () -> <logger,io> (), min : level = Debug,
             base : list<field> = [] ) : io list<string>
  val out = sink()
  with-json-logger(fn(l) out.add(l), action, min, base, fixed)
  out.lines

fun main()
  run-tests([
    group("rendering", [
      test("one line of json per record", fn()
        val ls = capture({ info("started") })
        assert-equal(ls.length, 1)
        assert-equal(ls.head.default(""),
          "{\"level\":\"info\",\"ts\":1700000000000,\"msg\":\"started\"}")
      ),
      test("fields appear in order", fn()
        val ls = capture({ info("hi", [("b","2"),("a","1")]) })
        assert-equal(ls.head.default(""),
          "{\"level\":\"info\",\"ts\":1700000000000,\"msg\":\"hi\",\"b\":\"2\",\"a\":\"1\"}")
      ),
      test("messages and values are escaped", fn()
        val ls = capture({ info("a\"b", [("k","v\nw")]) })
        assert-true(ls.head.default("").contains("a\\\"b"))
        assert-true(ls.head.default("").contains("v\\nw"))
      ),
      test("every level renders", fn()
        val ls = capture({ debug("d"); info("i"); warn("w"); error("e") })
        assert-equal(ls.length, 4)
        assert-true(ls.head.default("").contains("\"debug\""))
      ),
      test("int and bool fields", fn()
        val ls = capture({ info("n", [int/field("count", 42), bool/field("ok", True)]) })
        assert-true(ls.head.default("").contains("\"count\":\"42\""))
        assert-true(ls.head.default("").contains("\"ok\":\"true\""))
      ),
    ]),

    group("levels", [
      test("records below the minimum are dropped", fn()
        val ls = capture({ debug("d"); info("i") }, Info)
        assert-equal(ls.length, 1)
        assert-true(ls.head.default("").contains("\"msg\":\"i\""))
      ),
      test("nothing is emitted above error", fn()
        val ls = capture({ debug("d"); info("i"); warn("w") }, Error)
        assert-equal(ls.length, 0)
      ),
      test("a scoped minimum composes with the destination minimum", fn()
        val ls = capture({
          info("outside")
          with-min-level(Warn, { debug("d"); info("i"); warn("w"); error("e") })
          info("after")
        }, Info)
        assert-equal(ls.length, 4)
        assert-true(ls.any(fn(l) l.contains("\"msg\":\"w\"")))
        assert-false(ls.any(fn(l) l.contains("\"msg\":\"i\"")))
      ),
    ]),

    group("context", [
      test("handler fields are on every record", fn()
        val ls = capture({ info("a"); info("b") }, Debug, [("service","demo")])
        assert-equal(ls.length, 2)
        assert-true(ls.head.default("").contains("\"service\":\"demo\""))
      ),
      test("with-context adds fields to nested records", fn()
        val ls = capture({ with-context([("request-id","r1")], { info("handled") }) },
                         Debug, [("service","demo")])
        val line = ls.head.default("")
        assert-true(line.contains("\"service\":\"demo\""), line)
        assert-true(line.contains("\"request-id\":\"r1\""), line)
      ),
      test("context does not leak out of its scope", fn()
        val ls = capture({
          with-context([("request-id","r1")], { info("inside") })
          info("outside")
        }, Debug)
        assert-true(ls.head.default("").contains("r1"))
        assert-false((ls.drop(1).head.default("")).contains("r1"),
                     "the request id leaked: " ++ ls.drop(1).head.default(""))
      ),
      test("contexts nest", fn()
        val ls = capture({
          with-context([("a","1")], { with-context([("b","2")], { info("deep") }) })
        }, Debug)
        val line = ls.head.default("")
        assert-true(line.contains("\"a\":\"1\""), line)
        assert-true(line.contains("\"b\":\"2\""), line)
      ),
      test("redaction covers call-site and nested context fields", fn()
        val ls = capture({
          with-redaction(["password","token"], {
            with-context([("token","context-secret")], {
              info("login", [("user","alice"),("password","call-secret")])
            })
          })
        }, Debug)
        val line = ls.head.default("")
        assert-true(line.contains("\"token\":\"[REDACTED]\""), line)
        assert-true(line.contains("\"password\":\"[REDACTED]\""), line)
        assert-true(line.contains("\"user\":\"alice\""), line)
        assert-false(line.contains("context-secret"), line)
        assert-false(line.contains("call-secret"), line)
      ),
      test("redact-fields preserves order and supports a custom marker", fn()
        val fs = redact-fields([("a","1"),("secret","x"),("b","2")],
                               ["secret"], "***")
        assert-equal(fs.show, [("a","1"),("secret","***"),("b","2")].show)
      ),
    ]),

    group("the discarding handler", [
      // An outer capturing logger is installed and then shadowed.  Asserting
      // that the outer sink stays empty is what shows the discarding handler
      // really discards rather than delegating outwards; `assert-true(True)`
      // passed just as well if both records had been forwarded.
      test("swallows everything, and does not delegate outwards", fn()
        val ls = capture(fn()
          info("this one is seen")
          with-no-logger({ info("nobody sees this"); error("nor this") })
        )
        assert-equal(ls.length, 1, "records escaped the discarding handler: " ++ ls.show)
      ),
    ]),
  ])
