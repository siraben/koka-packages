import std/os/env
import sqlite/db

val fixture-rows : int = 100000

fun arguments() : io (int, string)
  val args = get-args()
  val lookups = args.head("").parse-int.default(0)
  val path = args.drop(1).head("")
  if lookups <= 0 then throw("lookup count must be positive")
  if path == "" then throw("database path is required")
  (lookups, path)

fun query-loop( d : database, lookups : int ) : io (int, int)
  with-statement(d, "SELECT i, text_value FROM bench WHERE i = ?") fn(s)
    fun go( n : int, sum-i : int, text-bytes : int ) : io (int, int)
      if n >= lookups then (sum-i, text-bytes)
      else
        val key = (n * 48271) % fixture-rows
        s.reset
        s.bind(1, SqlInt(key))
        if !s.step then throw("indexed lookup missed key " ++ key.show)
        val row = s.current-row
        val found = row.int-at("i").default(-1)
        val text = row.text-at("text_value").default("")
        go(n + 1, sum-i + found, text-bytes + text.count)
    go(0, 0, 0)

fun main()
  val (lookups, path) = arguments()
  with-database(path) fn(d)
    val (sum-i, text-bytes) = query-loop(d, lookups)
    println("lookups=" ++ lookups.show ++
            " sum_i=" ++ sum-i.show ++
            " text_bytes=" ++ text-bytes.show)
