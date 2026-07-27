import sqlite/db
import std/os/env

fun positive-work() : io int
  val n = get-args().head("").parse-int.default(0)
  if n <= 0 then throw("row count must be positive")
  n

fun insert-rows( d : database, n : int ) : io ()
  with-statement(d, "INSERT INTO bench (i, text_value) VALUES (?, ?)") fn(s)
    fun go( i : int ) : io ()
      if i >= n then ()
      else
        s.reset
        s.bind-all([SqlInt(i), SqlText("row-" ++ i.show)])
        while { s.step } { () }
        go(i + 1)
    go(0)

fun required-int( r : row, name : string ) : io int
  match r.int-at(name)
    Just(i) -> i
    Nothing -> throw("missing integer result column " ++ name.show)

fun main()
  val n = positive-work()
  with-database(":memory:") fn(d)
    d.execute("CREATE TABLE bench (i INTEGER NOT NULL, text_value TEXT NOT NULL)")
    with-transaction(d) { insert-rows(d, n) }
    val r = d.query-one(
      "SELECT count(*) AS rows, sum(i) AS sum_i, " ++
      "sum(length(CAST(text_value AS BLOB))) AS text_bytes FROM bench"
    ).default(Row([], []))
    println("rows=" ++ r.required-int("rows").show ++
            " sum_i=" ++ r.required-int("sum_i").show ++
            " text_bytes=" ++ r.required-int("text_bytes").show)
