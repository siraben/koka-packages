/* What this measures, and why.

   SQLite itself is not the subject; the wrapper is.  So every row is chosen to
   isolate a cost the wrapper adds or removes:

   * `run` prepares, binds, steps and finalises for each call.  `with-statement`
     plus `reset` prepares once and reuses.  The gap between those two rows is
     what a prepared statement is worth here.
   * inserts inside one `with-transaction` against inserts each in their own
     implicit transaction, which on a real filesystem is the difference between
     one fsync and `n` of them.
   * `query-one` against `query`, because `query-one` steps directly rather
     than going through `all-rows` with `max-rows = 1`.

   The database is `:memory:`, so no row here includes disk latency.  That is
   deliberate: the point is the per-call cost of the binding, and a disk number
   would drown it.
*/
import kktest/bench
import sqlite/db

fun fresh() : io database
  val d = open(":memory:")
  d.execute("CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT NOT NULL, n INTEGER)")
  d

fun insert-run( d : database, n : int ) : io int
  fun go( i : int ) : io ()
    if i >= n then ()
    else
      d.run("INSERT INTO items (id, name, n) VALUES (?, ?, ?)",
            [SqlInt(i), SqlText("item-" ++ i.show), SqlInt(i * 3)])
      go(i + 1)
  go(0)
  n

// One prepared statement, reset between rows.
fun insert-prepared( d : database, n : int ) : io int
  with-statement(d, "INSERT INTO items (id, name, n) VALUES (?, ?, ?)") fn(s)
    fun go( i : int ) : io ()
      if i >= n then ()
      else
        s.reset
        s.bind-all([SqlInt(i), SqlText("item-" ++ i.show), SqlInt(i * 3)])
        while { s.step } { () }
        go(i + 1)
    go(0)
  n

fun point-lookups( d : database, n : int ) : io int
  fun go( i : int, seen : int ) : io int
    if i >= n then seen
    else
      val hit = match d.query-one("SELECT n FROM items WHERE id = ?", [SqlInt(i)])
                  Just(r) -> match r.int-at("n")
                               Just(v) -> v
                               Nothing -> 0
                  Nothing -> 0
      go(i + 1, seen + hit)
  go(0, 0)

fun scan( d : database, reps : int, max-rows : int ) : io int
  fun go( i : int, seen : int ) : io int
    if i >= reps then seen
    else go(i + 1, seen + d.query("SELECT id, name, n FROM items", [], max-rows).length)
  go(0, 0)

fun with-txn( n : int ) : io int
  with-database(":memory:") fn(d)
    d.execute("CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT NOT NULL, n INTEGER)")
    with-transaction(d) { insert-prepared(d, n) }

fun without-txn( n : int ) : io int
  with-database(":memory:") fn(d)
    d.execute("CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT NOT NULL, n INTEGER)")
    insert-prepared(d, n)

fun populated( n : int ) : io database
  val d = fresh()
  with-transaction(d) { insert-prepared(d, n) }
  d

fun main()
  val d4  = populated(4000)
  val d16 = populated(16000)
  report("sqlite", [
    measure("insert via run (prepare per row)", 60000,
            fn() { val d = fresh(); val r = with-transaction(d) { insert-run(d, 60000) }; d.close; r }),
    measure("insert via one prepared statement", 60000,
            fn() { val d = fresh(); val r = with-transaction(d) { insert-prepared(d, 60000) }; d.close; r }),
    measure("insert inside one transaction",     60000, fn() with-txn(60000)),
    measure("insert with no explicit transaction",60000, fn() without-txn(60000)),
    measure("query-one, primary key hit (4k rows)", 60000, fn() point-lookups(d4, 60000)),
    measure("query-one, primary key hit (16k rows)",60000, fn() point-lookups(d16, 60000)),
    measure("query, full scan of 4k rows",       4000 * 60, fn() scan(d4, 60, 20000)),
    measure("query, full scan of 16k rows",     16000 * 15, fn() scan(d16, 15, 20000)),
  ])
