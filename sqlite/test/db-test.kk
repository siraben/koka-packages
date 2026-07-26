import kktest/assert
import kktest/runner
import kktest/tmp
import sqlite/db
import bytes/bytes

fun mem( action : (database) -> io a ) : io a
  with-database(":memory:", action)

fun schema( d : database ) : io ()
  d.execute("CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT NOT NULL UNIQUE, qty INTEGER)")

fun ints( rs : list<row> ) : div string
  rs.map(fn(r) r.int-at("id").default(-1).show).join(",")

// Bodies that must fail, named so the test can assert on them.
fun failing-query( d : database ) : io ()
  d.query("SELECT * FROM does_not_exist")
  ()

fun failing-prepare( d : database ) : io ()
  with-statement(d, "NOT VALID SQL") fn(_s) ()

fun rollback-case( d : database ) : io ()
  with-transaction(d) fn()
    d.run("INSERT INTO items (name, qty) VALUES (?, ?)", [SqlText("rolled"), SqlInt(1)])
    throw("failing inside the transaction")

fun partial-consumption( d : database ) : io int
  // Take one row from a multi-row query and stop; the statement must still be
  // finalised by its scope.
  with-statement(d, "SELECT id FROM items") fn(s)
    s.step
    s.current-row.int-at("id").default(-1)

fun main()
  run-tests([
    group("connections", [
      test("open, use, close", fn()
        mem fn(d)
          d.schema
          d.run("INSERT INTO items (name, qty) VALUES (?, ?)", [SqlText("a"), SqlInt(1)])
          assert-equal(d.query("SELECT * FROM items").length, 1)
      ),
      test("a connection is closed on the way out", fn()
        val before = open-connections()
        mem fn(d) d.schema
        assert-equal(open-connections(), before)
      ),
      test("closing twice is not an error, and does not double-release", fn()
        val before = open-connections()
        val d = db/open(":memory:")
        assert-equal(open-connections(), before + 1)
        d.close
        d.close
        // the point of the test: the second close must not decrement again
        assert-equal(open-connections(), before)
      ),
      test("a file-backed database persists", fn()
        with-temp-dir fn(dir)
          val path = dir ++ "/test.db"
          with-database(path) fn(d)
            d.schema
            d.run("INSERT INTO items (name, qty) VALUES (?, ?)", [SqlText("kept"), SqlInt(7)])
          with-database(path) fn(d)
            val rs = d.query("SELECT name, qty FROM items")
            assert-equal(rs.length, 1)
            assert-equal(rs.head.default(Row([],[])).text-at("name").default(""), "kept")
      ),
    ]),

    group("prepared statements", [
      test("parameters are bound, not interpolated", fn()
        mem fn(d)
          d.schema
          // a value that would be catastrophic if it were interpolated
          val nasty = "x'); DROP TABLE items; --"
          d.run("INSERT INTO items (name, qty) VALUES (?, ?)", [SqlText(nasty), SqlInt(1)])
          val rs = d.query("SELECT name FROM items")
          assert-equal(rs.length, 1)
          assert-equal(rs.head.default(Row([],[])).text-at("name").default(""), nasty)
      ),
      test("every value type round trips", fn()
        mem fn(d)
          d.execute("CREATE TABLE t (i INTEGER, s TEXT, b BLOB, n INTEGER)")
          d.run("INSERT INTO t VALUES (?, ?, ?, ?)",
                [SqlInt(-5), SqlText("héllo"), SqlBlob(bytes([0,255,10])), SqlNull])
          val r = d.query-one("SELECT i, s, b, n FROM t").default(Row([],[]))
          assert-equal(r.int-at("i").default(0), -5)
          assert-equal(r.text-at("s").default(""), "héllo")
          match r.column("b")
            Just(SqlBlob(b)) -> assert-equal(b.list.show, [0,255,10].show)
            _ -> assert-fail("expected a blob")
          match r.column("n")
            Just(SqlNull) -> ()
            _ -> assert-fail("expected null")
      ),
      test("a statement can be reset and reused", fn()
        mem fn(d)
          d.schema
          with-statement(d, "INSERT INTO items (name, qty) VALUES (?, ?)") fn(s)
            s.bind-all([SqlText("one"), SqlInt(1)])
            s.step
            s.reset
            s.bind-all([SqlText("two"), SqlInt(2)])
            s.step
            ()
          assert-equal(d.query("SELECT id FROM items").length, 2)
      ),
      test("last-insert-id and changes", fn()
        mem fn(d)
          d.schema
          d.run("INSERT INTO items (name, qty) VALUES (?, ?)", [SqlText("a"), SqlInt(1)])
          assert-equal(d.last-insert-id, 1)
          d.run("UPDATE items SET qty = 9", [])
          assert-equal(d.changes, 1)
      ),
      test("a row limit is enforced", fn()
        mem fn(d)
          d.schema
          d.run("INSERT INTO items (name, qty) VALUES ('a', 1)", [])
          d.run("INSERT INTO items (name, qty) VALUES ('b', 2)", [])
          assert-throws({ d.query("SELECT * FROM items", [], 1) }, containing = "row limit")
      ),
    ]),

    group("errors", [
      test("a bad query is classified", fn()
        mem fn(d)
          assert-throws({ failing-query(d) }, containing = "malformed")
      ),
      test("a constraint violation is classified", fn()
        mem fn(d)
          d.schema
          d.run("INSERT INTO items (name, qty) VALUES (?, ?)", [SqlText("dup"), SqlInt(1)])
          match try({ d.run("INSERT INTO items (name, qty) VALUES (?, ?)",
                            [SqlText("dup"), SqlInt(2)]) })
            Error(ex) -> assert-true(ex.message.contains("constraint"), ex.message)
            Ok(_) -> assert-fail("expected a uniqueness violation")
      ),
      test("classification of the common codes", fn()
        assert-equal(classify(5).dberror/show, "busy")
        assert-equal(classify(19).dberror/show, "constraint")
        assert-equal(classify(1).dberror/show, "malformed")
        assert-equal(classify(-19).dberror/show, "constraint")
      ),
    ]),

    group("resource cleanup", [
      test("a successful query finalises its statement", fn()
        mem fn(d)
          d.schema
          val before = open-statements()
          d.query("SELECT * FROM items")
          assert-equal(open-statements(), before)
      ),
      test("a failed query finalises its statement", fn()
        mem fn(d)
          val before = open-statements()
          assert-throws({ failing-query(d) })
          assert-equal(open-statements(), before, "a failed query leaked a statement")
      ),
      test("a failed prepare leaks nothing", fn()
        mem fn(d)
          val before = open-statements()
          assert-throws({ failing-prepare(d) })
          assert-equal(open-statements(), before)
      ),
      test("partially consumed results are finalised", fn()
        mem fn(d)
          d.schema
          d.run("INSERT INTO items (name, qty) VALUES ('a', 1)", [])
          d.run("INSERT INTO items (name, qty) VALUES ('b', 2)", [])
          val before = open-statements()
          assert-equal(partial-consumption(d), 1)
          assert-equal(open-statements(), before,
                       "stopping early leaked a statement")
      ),
      test("closing a connection finalises its statements", fn()
        val before = open-statements()
        val d = db/open(":memory:")
        d.execute("CREATE TABLE t (a INTEGER)")
        d.prepare("SELECT * FROM t")
        d.prepare("SELECT a FROM t")
        assert-equal(open-statements(), before + 2)
        d.close
        assert-equal(open-statements(), before,
                     "closing the connection left statements open")
      ),
      test("many statements do not accumulate", fn()
        mem fn(d)
          d.schema
          val before = open-statements()
          var i := 0
          while { i < 500 }
            d.query("SELECT * FROM items")
            i := i + 1
          assert-equal(open-statements(), before)
      , timeout-s = 60),
    ]),

    group("transactions", [
      test("commit on success", fn()
        mem fn(d)
          d.schema
          with-transaction(d) fn()
            d.run("INSERT INTO items (name, qty) VALUES (?, ?)", [SqlText("kept"), SqlInt(1)])
          assert-equal(d.query("SELECT id FROM items").length, 1)
      ),
      test("rollback on failure", fn()
        mem fn(d)
          d.schema
          assert-throws({ rollback-case(d) }, containing = "failing inside")
          assert-equal(d.query("SELECT id FROM items").length, 0,
                       "the transaction was not rolled back")
      ),
      test("the database is usable after a rollback", fn()
        mem fn(d)
          d.schema
          assert-throws({ rollback-case(d) })
          d.run("INSERT INTO items (name, qty) VALUES (?, ?)", [SqlText("after"), SqlInt(1)])
          assert-equal(d.query("SELECT id FROM items").length, 1)
      ),
    ]),

    group("migrations", [
      test("applied in order, once", fn()
        mem fn(d)
          val ms = [ Migration(1, "create items",
                               "CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT)")
                   , Migration(2, "add qty", "ALTER TABLE items ADD COLUMN qty INTEGER") ]
          assert-equal(migrate(d, ms).show, ["create items","add qty"].show)
          // running again applies nothing
          assert-equal(migrate(d, ms).show, ([] : list<string>).show)
          d.run("INSERT INTO items (name, qty) VALUES ('a', 1)", [])
          assert-equal(d.query("SELECT id FROM items").length, 1)
      ),
      test("a new migration is applied to an existing database", fn()
        with-temp-dir fn(dir)
          val path = dir ++ "/m.db"
          val first = [ Migration(1, "one", "CREATE TABLE a (x INTEGER)") ]
          val both  = first ++ [ Migration(2, "two", "CREATE TABLE b (y INTEGER)") ]
          with-database(path) fn(d) migrate(d, first)
          with-database(path) fn(d)
            assert-equal(migrate(d, both).show, ["two"].show)
            d.run("INSERT INTO b VALUES (1)", [])
            assert-equal(d.query("SELECT y FROM b").length, 1)
      ),
      test("a failing migration leaves the schema untouched", fn()
        mem fn(d)
          val bad = [ Migration(1, "ok", "CREATE TABLE a (x INTEGER)")
                    , Migration(2, "broken", "THIS IS NOT SQL") ]
          assert-throws({ migrate(d, bad) })
          // the first migration committed, the second did not
          assert-equal(d.query("SELECT id FROM schema_migrations").length, 1)
      ),
    ]),
  ])
