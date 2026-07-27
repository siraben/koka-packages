# sqlite

SQLite with scoped connections, statements and transactions, and errors
classified into a small enumeration.  It wraps the established C library and
reimplements nothing.  `with-database` closes on every exit path,
`with-statement` finalises on every exit path, and `with-transaction` commits
on success and rolls back on failure or cancellation; closing a connection also
finalises every statement still open on it, so an abandoned statement cannot
keep the database file open.  Both `close` and `finalize` are idempotent, which
is what makes running them from a release action safe however the scope is
left.  It is deliberately *not* an ORM or a query builder: there is no schema
mapping, no relation loading, no SQL generation, no connection pool, no
prepared-statement cache, no floating-point column type, and no async — a query
blocks the calling thread, and on the single-threaded task runtime that means
it blocks the loop.

## Public API

### Connections

| declaration | signature | what it is |
| --- | --- | --- |
| `database` | `value struct { conn : int }` | |
| `open` | `(path : string, busy-ms : int = 5000) : io database` | `":memory:"` for an in-process database |
| `close` | `(d : database) : io ()` | Idempotent; finalises every statement still open on it |
| `is-open` | `(d : database) : io bool` | Whether a handle still names an open connection |
| `with-database` | `(path : string, action : (database) -> io a, busy-ms : int = 5000) : io a` | |
| `busy-timeout` | `(d : database, ms : int) : io ()` | How long to wait for another *process*'s write lock before reporting `Busy`; negative values are rejected |
| `execute` | `(d : database, sql : string) : io ()` | SQL with no result rows: migrations, pragmas, DDL |
| `last-insert-id` | `(d : database) : io int` | |
| `changes` | `(d : database) : io int` | |
| `version` | `() : io string` | |

### Statements

| declaration | signature | what it is |
| --- | --- | --- |
| `statement` | `value struct { stmt : int }` | |
| `prepare` | `(d : database, sql : string) : io statement` | |
| `finalize` | `(s : statement) : io ()` | Idempotent |
| `is-finalized` | `(s : statement) : io bool` | Also becomes true when the owning connection closes |
| `with-statement` | `(d : database, sql : string, action : (statement) -> io a) : io a` | Prepare, use, finalise — on success, on failure, and on cancellation |
| `reset` | `(s : statement) : io ()` | Clear bindings and rewind, so a prepared statement can be reused |
| `bind` | `(s : statement, index : int, v : value) : io ()` | 1-based, as SQLite counts |
| `bind-all` | `(s : statement, vs : list<value>) : io ()` | In order from index 1 |
| `step` | `(s : statement) : io bool` | `True` means a row is available |
| `current-row` | `(s : statement) : io row` | Only meaningful after `step` returned `True` |
| `all-rows` | `(s : statement, max-rows : int = 10000) : io list<row>` | Throws past the limit rather than exhausting memory |

### Queries

| declaration | signature | what it is |
| --- | --- | --- |
| `query` | `(d : database, sql : string, params : list<value> = [], max-rows : int = 10000) : io list<row>` | Finalises the statement afterwards, including when the caller stops early |
| `query-one` | `(d : database, sql : string, params : list<value> = []) : io maybe<row>` | Steps directly rather than going through `all-rows`, so a query matching more than one row does not throw the row-limit error |
| `run` | `(d : database, sql : string, params : list<value> = []) : io ()` | A statement that returns no rows |

### Values and rows

| declaration | signature | what it is |
| --- | --- | --- |
| `value` | `type { SqlNull; SqlInt(v); SqlText(v); SqlBlob(v : bytes) }` | |
| `show` | `(v : value) : string` | Qualify as `value/show` |
| `row` | `struct { columns : list<string>; values : list<value> }` | |
| `column` | `(r : row, name : string) : div maybe<value>` | |
| `int-at` / `text-at` | `(r : row, name : string) : div maybe<int>` / `div maybe<string>` | `Nothing` for a missing column *and* for one of the wrong type |

### Transactions and migrations

| declaration | signature | what it is |
| --- | --- | --- |
| `with-transaction` | `(d : database, action : () -> io a) : io a` | `BEGIN IMMEDIATE`, commit on success, roll back on failure or cancellation |
| `with-savepoint` | `(d : database, action : () -> io a) : io a` | A nestable transaction scope; works inside another savepoint or transaction |
| `migration` | `struct { version : int; name : string; sql : string }` | `version` must be stable and increasing |
| `migrate` | `(d : database, migrations : list<migration>) : io list<string>` | Sorts by version, rejects duplicate versions and renamed applied migrations, then applies pending steps transactionally |

The `COMMIT` is inside the same `try` as the action.  That is not a formality:
`COMMIT` can fail with `SQLITE_BUSY` when another connection holds a read lock,
and a commit that threw from outside the guarded region would leave the
transaction open on a connection the service goes on using — so later writes
fail as nested transactions and later reads see the write that was reported as
failed.  Rollback failures are swallowed: the interesting error is the one that
caused the rollback.

### Errors

Failures throw with SQLite's own message and carry `ExnSystem(code)`.
`classify(code) : db-error` reduces the result code to `Busy` (retryable),
`Constraint` (usually the caller's fault), `Malformed` (the SQL is wrong or a
value has the wrong type), or `OtherDbError(code)`.  Extended result codes share
the low byte, so `classify` looks at `code % 256`.

`open-statements()` and `open-connections()` report how many are still open.
The tests assert on these; a service does not need them.

## Complexity

| operation | cost |
| --- | --- |
| `prepare` | parses and plans the SQL — the expensive part of a one-shot query |
| `bind`, `step` | O(1) plus whatever the query plan costs |
| `current-row` over `k` columns | O(k), reading names and values |
| `all-rows` over `r` rows of `k` columns | O(r·k), accumulated with an explicit reverse rather than by appending |
| `query`, `run` | one `prepare` + `bind-all` + steps + one `finalize` |
| `query-one` | one `prepare`, **one** `step`, one `finalize` |
| `column`, `int-at`, `text-at` over `k` columns | O(k) — two parallel lists, not a map |
| `migrate` over `m` migrations with `a` already applied | one query, O(m²) insertion sort, then O(m·a) history checks; migration lists are expected to be small |

Measured on this machine (AMD Ryzen 9 5950X, 32 threads, 126 GiB, Linux 7.0.1
x86_64, Koka 3.2.7, `--release`, fastest of 3), against `:memory:` so that no
row includes disk latency:

| what | n | ms | units/s |
| --- | ---: | ---: | ---: |
| insert via `run` (prepare per row) | 60 000 | 147 | 408 163 |
| insert via one prepared statement | 60 000 | 53 | 1 132 075 |
| insert inside one transaction | 60 000 | 47 | 1 276 595 |
| insert with no explicit transaction | 60 000 | 76 | 789 473 |
| `query-one`, primary key hit (4k rows) | 60 000 | 121 | 495 867 |
| `query-one`, primary key hit (16k rows) | 60 000 | 121 | 495 867 |
| `query`, full scan of 4k rows | 240 000 | 153 | 1 568 627 |
| `query`, full scan of 16k rows | 240 000 | 147 | 1 632 653 |

Preparing per row costs 2.8x what reusing one prepared statement does — 2.4 µs
against 0.9 µs — which is what `with-statement` plus `reset` is worth.  An
explicit transaction is worth 1.6x even in memory, where there is no fsync to
save; on disk the gap is far larger.  `query-one` is flat between 4 000 and
16 000 rows, which is the index doing its job, and a full scan costs about
0.6 µs per row either way.

Reproduce with `./run-benchmarks.sh sqlite` from the repository root.

## Worked example

```koka
import sqlite/db

val schema : list<migration> =
  [ Migration(1, "create items",
      "CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT NOT NULL, n INTEGER)")
  , Migration(2, "index by name",
      "CREATE INDEX items_by_name ON items (name)") ]

fun main()
  with-database(":memory:") fn(d)
    // Migrations are idempotent: the second call applies nothing.
    println("applied: " ++ d.migrate(schema).join(", "))
    println("applied: " ++ d.migrate(schema).join(", ") ++ "(nothing)")

    // Writes, in one transaction: committed together or not at all.
    with-transaction(d) fn()
      d.run("INSERT INTO items (name, n) VALUES (?, ?)", [SqlText("widget"), SqlInt(7)])
      d.run("INSERT INTO items (name, n) VALUES (?, ?)", [SqlText("gadget"), SqlInt(12)])

    // A point read.
    match d.query-one("SELECT n FROM items WHERE name = ?", [SqlText("widget")])
      Nothing -> println("no widget")
      Just(r) ->
        match r.int-at("n")
          Just(n) -> println("widget: " ++ n.show)
          Nothing -> println("widget has no integer column n")

    // A failed transaction leaves nothing behind.
    fun doomed() : io ()
      with-transaction(d) fn()
        d.run("INSERT INTO items (name, n) VALUES (?, ?)",
              [SqlText("doomed"), SqlInt(1)])
        throw("changed my mind")
    match try(doomed)
      Error(_) -> ()
      Ok(_)    -> println("unexpectedly committed")
    println(d.query("SELECT id FROM items").length.show ++ " rows")   // 2
```

## Limits

* **Everything blocks.**  A query runs on the calling thread, and the task
  runtime is single threaded and cooperative, so a slow query stalls every
  other connection the server is handling.  Nothing here yields to the loop.
  Keep queries indexed and small, or move them off the loop, which this package
  gives you no way to do.
* **No connection pool.**  One connection is used by one task at a time by
  construction, which is why `busy-timeout` is about another *process* rather
  than another task.
* **No floating-point column type.**  A REAL column is surfaced as `SqlText`
  rather than silently losing precision, because this program's schema has
  none.  A caller with a REAL column gets a string and has to parse it.
* **`all-rows` and `query` are capped at 10 000 rows** by default and throw
  past it.  That is deliberate — a query matching far more than expected should
  fail loudly — but it means paging is the caller's job.
* **`query-one` does not check for a second row.**  It steps once and returns.
  A query that matches several rows silently yields the first.
* **`migrate` is forward-only.**  There is no down migration or checksum of
  the SQL that ran. It detects a reused version with a different name, but not
  SQL text that changed while keeping the same version and name.
* **`classify` maps six result codes**; everything else is `OtherDbError`.
  Extended codes are reduced to their low byte, so `SQLITE_CONSTRAINT_UNIQUE`
  and `SQLITE_CONSTRAINT_CHECK` are both `Constraint`.
* **`classify` cannot tell SQLite's codes from the binding's own.**  The C
  layer answers `-SQLITE_MISUSE` when it is handed an id for a connection or
  statement it does not know about — a bookkeeping failure of this package, not
  of SQLite — and that arrives at `classify` looking exactly like a genuine
  `SQLITE_MISUSE`.  Reaching it takes using a handle after it was closed.
* **Handles are runtime-checked, not affine.** `is-open` and `is-finalized`
  expose lifetime state, and operations that reach the native registry with a
  stale id report `SQLITE_MISUSE`; the type system does not prevent retaining a
  handle after its scope.
* **`column`, `int-at` and `text-at` scan two parallel lists.**  Reading many
  columns out of many rows is O(rows · columns²) if every column is looked up
  by name.
* **`int-at` and `text-at` conflate "missing" with "wrong type".**  Both give
  `Nothing`.  Use `column` when the difference matters.
