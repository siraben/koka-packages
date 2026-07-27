/* SQLite, with scoped resources and classified errors.

   Wraps the established SQLite C library; nothing is reimplemented.

   ## Resources

   Connections, statements and transactions are all scoped.  `with-database`
   closes on every exit path, `with-statement` finalises on every exit path,
   and `with-transaction` commits on success and rolls back on failure or
   cancellation.  Closing a connection also finalises every statement still
   open on it, so an abandoned statement cannot keep the database file open.

   Both `close` and `finalize` are idempotent, which is what makes running them
   from a release action safe no matter how the scope is left.

   ## Errors

   Failures throw with SQLite's own message, and `classify` turns the result
   code into a small enumeration so a service can distinguish "the client sent
   something invalid" from "the database is busy" from "something is wrong with
   us".

   ## Concurrency

   The task runtime is single threaded, so a connection is used by one task at
   a time by construction.  `busy-timeout` still matters because another
   *process* may hold the write lock.
*/
module sqlite/db

import std/num/int32
import std/num/int64
import bytes/bytes
import resource/scope

extern import
  c file "sqlite-inline.c"

pub value struct database( conn : int )
pub value struct statement( stmt : int )

// A value going into, or coming out of, a column.
pub type value
  SqlNull
  SqlInt( v : int )
  SqlText( v : string )
  SqlBlob( v : bytes )

pub fun value/show( v : value ) : string
  match v
    SqlNull    -> "null"
    SqlInt(i)  -> i.show
    SqlText(s) -> s.show
    SqlBlob(b) -> "blob(" ++ b.length.show ++ ")"

// A row: the values in column order, with the column names alongside.
pub struct row
  columns : list<string>
  values  : list<value>

pub fun column( r : row, name : string ) : div maybe<value>
  lookup-column(r.columns, r.values, name)

fun lookup-column( names : list<string>, vals : list<value>, name : string ) : div maybe<value>
  match (names, vals)
    (Cons(n, ns), Cons(v, vs)) -> if n == name then Just(v) else lookup-column(ns, vs, name)
    _ -> Nothing

pub fun int-at( r : row, name : string ) : div maybe<int>
  match r.column(name)
    Just(SqlInt(i)) -> Just(i)
    _               -> Nothing

pub fun text-at( r : row, name : string ) : div maybe<string>
  match r.column(name)
    Just(SqlText(s)) -> Just(s)
    _                -> Nothing

// ----------------------------------------------------------------------------
// errors
// ----------------------------------------------------------------------------

pub type db-error
  // The database (or a table) is locked by someone else.  Retryable.
  Busy
  // A constraint was violated: usually the caller's fault.
  Constraint
  // The SQL is wrong, or a value has the wrong type.
  Malformed
  // Anything else.
  OtherDbError( code : int )

pub fun classify( code : int ) : db-error
  val c = if code < 0 then 0 - code else code
  // sqlite result codes; the extended codes share the low byte
  match c % 256
    5  -> Busy          // SQLITE_BUSY
    6  -> Busy          // SQLITE_LOCKED
    19 -> Constraint    // SQLITE_CONSTRAINT
    1  -> Malformed     // SQLITE_ERROR
    20 -> Malformed     // SQLITE_MISMATCH
    25 -> Malformed     // SQLITE_RANGE
    _  -> OtherDbError(c)

pub fun dberror/show( e : db-error ) : string
  match e
    Busy            -> "busy"
    Constraint      -> "constraint"
    Malformed       -> "malformed"
    OtherDbError(c) -> "sqlite error " ++ c.show

fun fail( what : string, code : int ) : io a
  // The C layer reports failure as a negative result code; the exception
  // carries the code the way sqlite writes it.
  val c = if code < 0 then 0 - code else code
  throw("sqlite: " ++ what ++ ": " ++ prim-last-error() ++
        " (" ++ classify(c).dberror/show ++ ")", ExnSystem(c))

// ----------------------------------------------------------------------------
// connections
// ----------------------------------------------------------------------------

// Open (or create) a database.  Use ":memory:" for an in-process database.
pub fun open( path : string, busy-ms : int = 5000 ) : io database
  if busy-ms < 0 then throw("sqlite: busy timeout must not be negative")
  val id = prim-open(path).int
  if id < 0 then fail("cannot open " ++ path.show, id)
  val d = Database(id)
  d.busy-timeout(busy-ms)
  d

// Close.  Idempotent, and finalises every statement still open on the
// connection so an abandoned statement cannot keep the file open.
pub fun close( d : database ) : io ()
  prim-close(d.conn.int64)
  ()

// Whether this handle still names an open connection.
pub fun is-open( d : database ) : io bool
  prim-is-open(d.conn.int64).int == 1

pub fun with-database( path : string, action : (database) -> io a,
                       busy-ms : int = 5000 ) : io a
  with-resource({ open(path, busy-ms) }, close, action)

// How long to wait for another process's write lock before reporting `Busy`.
pub fun busy-timeout( d : database, ms : int ) : io ()
  if ms < 0 then throw("sqlite: busy timeout must not be negative")
  val rc = prim-busy-timeout(d.conn.int64, ms.int32).int
  if rc < 0 then fail("cannot set busy timeout", rc)

// Run SQL with no result rows: migrations, pragmas, DDL.
pub fun execute( d : database, sql : string ) : io ()
  val rc = prim-exec(d.conn.int64, sql).int
  if rc < 0 then fail("cannot execute", rc)

pub fun last-insert-id( d : database ) : io int
  if !d.is-open then fail("connection is closed", 21) // SQLITE_MISUSE
  prim-last-insert-id(d.conn.int64).int

pub fun changes( d : database ) : io int
  if !d.is-open then fail("connection is closed", 21) // SQLITE_MISUSE
  prim-changes(d.conn.int64).int

// ----------------------------------------------------------------------------
// statements
// ----------------------------------------------------------------------------

pub fun prepare( d : database, sql : string ) : io statement
  val id = prim-prepare(d.conn.int64, sql).int
  if id < 0 then fail("cannot prepare " ++ sql.show, id)
  Statement(id)

// Finalize.  Idempotent.
pub fun finalize( s : statement ) : io ()
  prim-finalize(s.stmt.int64)
  ()

// Whether this handle has been finalized, directly or by closing its database.
pub fun is-finalized( s : statement ) : io bool
  prim-is-finalized(s.stmt.int64).int == 1

// Prepare, use, finalize -- on success, on failure, and on cancellation.
pub fun with-statement( d : database, sql : string,
                        action : (statement) -> io a ) : io a
  with-resource({ prepare(d, sql) }, finalize, action)

// Clear bindings and rewind, so a prepared statement can be reused.
pub fun reset( s : statement ) : io ()
  val rc = prim-reset(s.stmt.int64).int
  if rc < 0 then fail("cannot reset a statement", rc)

// Bind parameters, 1-based as SQLite counts them.
pub fun bind( s : statement, index : int, v : value ) : io ()
  val rc = match v
             SqlNull    -> prim-bind-null(s.stmt.int64, index.int32).int
             SqlInt(i)  -> prim-bind-int(s.stmt.int64, index.int32, i.int64).int
             SqlText(t) -> prim-bind-text(s.stmt.int64, index.int32, t).int
             SqlBlob(b) -> prim-bind-blob(s.stmt.int64, index.int32, b.unsafe-bytes-raw).int
  if rc < 0 then fail("cannot bind parameter " ++ index.show, rc)

// Bind a whole parameter list in order.
pub fun bind-all( s : statement, vs : list<value> ) : io ()
  bind-from(s, vs, 1)

fun bind-from( s : statement, vs : list<value>, i : int ) : io ()
  match vs
    Nil -> ()
    Cons(v, rest) -> { s.bind(i, v); bind-from(s, rest, i + 1) }

// ----------------------------------------------------------------------------
// stepping and rows
// ----------------------------------------------------------------------------

// Advance.  `True` means a row is available.
pub fun step( s : statement ) : io bool
  val rc = prim-step(s.stmt.int64).int
  if rc < 0 then fail("cannot step", rc)
  rc == 1

// The current row.  Only meaningful after `step` returned True.
pub fun current-row( s : statement ) : io row
  val n = prim-column-count(s.stmt.int64).int
  Row(read-names(s, 0, n, []), read-values(s, 0, n, []))

fun read-names( s : statement, i : int, n : int, acc : list<string> ) : io list<string>
  if i >= n then acc.reverse
  else read-names(s, i + 1, n, Cons(prim-column-name(s.stmt.int64, i.int32), acc))

fun read-values( s : statement, i : int, n : int, acc : list<value> ) : io list<value>
  if i >= n then acc.reverse
  else read-values(s, i + 1, n, Cons(read-value(s, i), acc))

fun read-value( s : statement, i : int ) : io value
  match prim-column-type(s.stmt.int64, i.int32).int
    1 -> SqlInt(prim-column-int(s.stmt.int64, i.int32).int)
    // SQLITE_FLOAT.  `value` has no float case, so a REAL column comes back as
    // sqlite's own decimal rendering of it rather than losing precision to an
    // int -- and a caller cannot tell it apart from a genuine TEXT column.
    // Named rather than left to the wildcard below, because it is a case this
    // package really can meet and has decided what to do about.
    2 -> SqlText(prim-column-text(s.stmt.int64, i.int32))
    3 -> SqlText(prim-column-text(s.stmt.int64, i.int32))
    4 -> SqlBlob(unsafe-bytes-from-raw(prim-column-blob(s.stmt.int64, i.int32)))
    5 -> SqlNull
    // sqlite defines no other storage class; a new one would be a library
    // change, and text is the only rendering that cannot lose the value.
    _ -> SqlText(prim-column-text(s.stmt.int64, i.int32))

// Every remaining row.  Bounded by `max-rows` so a query that matches far more
// than expected fails loudly instead of exhausting memory.
pub fun all-rows( s : statement, max-rows : int = 10000 ) : io list<row>
  collect(s, [], 0, max-rows)

fun collect( s : statement, acc : list<row>, n : int, max-rows : int ) : io list<row>
  if !s.step then acc.reverse
  elif n >= max-rows then
    throw("sqlite: query returned more than the " ++ max-rows.show ++ " row limit")
  else collect(s, Cons(s.current-row, acc), n + 1, max-rows)

// Run a query and hand back the rows, finalising the statement afterwards --
// including when the caller stops consuming early, because the statement is
// scoped rather than left to a finaliser.
pub fun query( d : database, sql : string, params : list<value> = [],
               max-rows : int = 10000 ) : io list<row>
  with-statement(d, sql) fn(s)
    s.bind-all(params)
    s.all-rows(max-rows)

// Run a statement that returns no rows.
pub fun run( d : database, sql : string, params : list<value> = [] ) : io ()
  with-statement(d, sql) fn(s)
    s.bind-all(params)
    while { s.step } { () }

// The first row, if any.
//
// Stepped directly rather than via `query(.., max-rows = 1)`: that would step a
// second time to discover the end of the result and throw the row-limit error
// on any query matching more than one row, which is not what "the first row"
// promises.
pub fun query-one( d : database, sql : string, params : list<value> = [] ) : io maybe<row>
  with-statement(d, sql) fn(s)
    s.bind-all(params)
    if s.step then Just(s.current-row) else Nothing

// ----------------------------------------------------------------------------
// transactions
// ----------------------------------------------------------------------------

// Run `action` in a transaction: commit on success, roll back on failure or
// cancellation.
//
// The COMMIT is inside the same `try` as the action.  It is not a formality:
// `COMMIT` can fail with SQLITE_BUSY when another connection holds a read
// lock, and a commit that throws from outside the guarded region would leave
// the transaction open on a connection this service goes on using -- so later
// writes fail as nested transactions and later reads see the write that was
// reported as failed.
//
// Rollback failures are swallowed: the interesting error is the one that
// caused the rollback, and a rollback that fails on an already-aborted
// transaction says nothing useful.
pub fun with-transaction( d : database, action : () -> io a ) : io a
  d.execute("BEGIN IMMEDIATE")
  match try({ val x = action(); d.execute("COMMIT"); x })
    Ok(x)     -> x
    Error(ex) ->
      try({ d.execute("ROLLBACK") })
      throw-exn(ex)

// A composable transaction scope. Savepoints can be nested, including inside
// `with-transaction`; SQLite resolves the repeated internal name to the most
// recently opened savepoint.
pub fun with-savepoint( d : database, action : () -> io a ) : io a
  d.execute("SAVEPOINT koka_package_savepoint")
  match try({ val x = action(); d.execute("RELEASE koka_package_savepoint"); x })
    Ok(x)     -> x
    Error(ex) ->
      try({ d.execute("ROLLBACK TO koka_package_savepoint");
            d.execute("RELEASE koka_package_savepoint") })
      throw-exn(ex)

// ----------------------------------------------------------------------------
// migrations
// ----------------------------------------------------------------------------

// One schema step. `version` must be stable and unique; `migrate` sorts the
// input, so declaration order is not significant.
pub struct migration
  version : int
  name    : string
  sql     : string

// Apply every migration that has not run yet, each in its own transaction, in
// ascending version order. Duplicate input versions and a changed name for an
// already-recorded version are rejected. Running this twice is a no-op.
pub fun migrate( d : database, migrations : list<migration> ) : io list<string>
  val ordered = sort-migrations(migrations)
  validate-migrations(ordered)
  d.execute("CREATE TABLE IF NOT EXISTS schema_migrations (" ++
            "id INTEGER PRIMARY KEY, name TEXT NOT NULL)")
  // `filter-map`, not a `-1` for a row that does not look like a version: a
  // sentinel version is a version, and it would compare equal to a migration
  // that happened to declare it.
  val applied = d.query("SELECT id, name FROM schema_migrations").filter-map(applied-row)
  ordered.foldl([], fn(done, m) apply-one(d, applied, done, m))

alias applied-migration = (int, string)

fun applied-row( r : row ) : div maybe<applied-migration>
  match (r.int-at("id"), r.text-at("name"))
    (Just(id), Just(name)) -> Just((id, name))
    _                      -> Nothing

fun sort-migrations( migrations : list<migration> ) : div list<migration>
  migrations.foldl([], insert-migration)

fun insert-migration( ordered : list<migration>, m : migration ) : div list<migration>
  match ordered
    Nil -> [m]
    Cons(x, xs) ->
      if m.version < x.version then Cons(m, ordered)
      else Cons(x, insert-migration(xs, m))

fun validate-migrations( ordered : list<migration> ) : <div,exn> ()
  match ordered
    Cons(a, Cons(b, _)) ->
      if a.version == b.version then
        throw("sqlite: duplicate migration version " ++ a.version.show)
      validate-migrations(ordered.tail)
    _ -> ()

fun applied-name( applied : list<applied-migration>, version : int ) : div maybe<string>
  match applied
    Nil -> Nothing
    Cons(a, rest) -> if a.fst == version then Just(a.snd) else applied-name(rest, version)

fun apply-one( d : database, applied : list<applied-migration>, done : list<string>,
               m : migration ) : io list<string>
  match applied-name(applied, m.version)
    Just(recorded-name) ->
      if !(recorded-name == m.name) then
        throw("sqlite: migration " ++ m.version.show ++ " was recorded as " ++
              recorded-name.show ++ " but is now named " ++ m.name.show)
      done
    Nothing ->
      with-transaction(d) fn()
        d.execute(m.sql)
        d.run("INSERT INTO schema_migrations (id, name) VALUES (?, ?)",
              [SqlInt(m.version), SqlText(m.name)])
      done ++ [m.name]

// ----------------------------------------------------------------------------
// diagnostics
// ----------------------------------------------------------------------------

pub fun version() : io string
  prim-version()

// How many statements and connections are still open.  The tests assert on
// these; a service does not need them.
pub fun open-statements() : io int
  prim-open-statements().int

pub fun open-connections() : io int
  prim-open-connections().int

// ----------------------------------------------------------------------------
// primitives
// ----------------------------------------------------------------------------

extern prim-open( path : string ) : io int64
  c "kk_sq_open"
extern prim-close( db : int64 ) : io int32
  c "kk_sq_close"
extern prim-is-open( db : int64 ) : io int32
  c "kk_sq_is_open"
extern prim-exec( db : int64, sql : string ) : io int32
  c "kk_sq_exec"
extern prim-busy-timeout( db : int64, ms : int32 ) : io int32
  c "kk_sq_busy_timeout"
extern prim-last-insert-id( db : int64 ) : io int64
  c "kk_sq_last_insert_id"
// `int64`, like every other connection id here: `kk_sq_changes` takes an
// `int64_t`, and declaring it `int32` handed the C side a narrowed argument.
extern prim-changes( db : int64 ) : io int32
  c "kk_sq_changes"
extern prim-prepare( db : int64, sql : string ) : io int64
  c "kk_sq_prepare"
extern prim-finalize( s : int64 ) : io int32
  c "kk_sq_finalize"
extern prim-is-finalized( s : int64 ) : io int32
  c "kk_sq_is_finalized"
extern prim-reset( s : int64 ) : io int32
  c "kk_sq_reset"
extern prim-bind-int( s : int64, idx : int32, v : int64 ) : io int32
  c "kk_sq_bind_int"
extern prim-bind-text( s : int64, idx : int32, v : string ) : io int32
  c "kk_sq_bind_text"
extern prim-bind-blob( s : int64, idx : int32, v : any ) : io int32
  c "kk_sq_bind_blob"
extern prim-bind-null( s : int64, idx : int32 ) : io int32
  c "kk_sq_bind_null"
extern prim-step( s : int64 ) : io int32
  c "kk_sq_step"
extern prim-column-count( s : int64 ) : io int32
  c "kk_sq_column_count"
extern prim-column-type( s : int64, col : int32 ) : io int32
  c "kk_sq_column_type"
extern prim-column-name( s : int64, col : int32 ) : io string
  c "kk_sq_column_name"
extern prim-column-int( s : int64, col : int32 ) : io int64
  c "kk_sq_column_int"
extern prim-column-text( s : int64, col : int32 ) : io string
  c "kk_sq_column_text"
extern prim-column-blob( s : int64, col : int32 ) : io any
  c "kk_sq_column_blob"
extern prim-last-error() : io string
  c "kk_sq_last_error"
extern prim-version() : io string
  c "kk_sq_version"
extern prim-open-statements() : io int32
  c "kk_sq_open_statements"
extern prim-open-connections() : io int32
  c "kk_sq_open_connections"
