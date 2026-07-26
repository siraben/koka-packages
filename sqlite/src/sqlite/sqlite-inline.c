/* SQLite binding.

   Connections and statements are named by integer ids rather than pointers, so
   no raw handle reaches Koka.  Every function reports failure as a negative
   SQLite result code; the Koka side classifies and throws.

   Row values are read back one column at a time through the `kk_sq_col_*`
   accessors after `kk_sq_step` reports a row, which avoids constructing Koka
   data structures in C.
*/
#include <sqlite3.h>
#include <stdlib.h>
#include <string.h>

typedef struct kk_db_s {
  int64_t         id;
  sqlite3*        db;
  struct kk_db_s* next;
} kk_db_t;

typedef struct kk_stmt_s {
  int64_t           id;
  sqlite3_stmt*     stmt;
  int64_t           db_id;
  struct kk_stmt_s* next;
} kk_stmt_t;

static kk_db_t*   g_dbs = NULL;
static kk_stmt_t* g_stmts = NULL;
static int64_t    g_sq_next_id = 1;

/* the message for the most recent failure, so Koka can report it */
static char g_sq_error[512] = {0};

static void kk_sq_set_error(sqlite3* db, const char* fallback) {
  const char* m = (db != NULL) ? sqlite3_errmsg(db) : fallback;
  if (m == NULL) m = fallback;
  snprintf(g_sq_error, sizeof(g_sq_error), "%s", m);
}

static kk_db_t* kk_sq_find_db(int64_t id) {
  for (kk_db_t* d = g_dbs; d != NULL; d = d->next) if (d->id == id) return d;
  return NULL;
}

static kk_stmt_t* kk_sq_find_stmt(int64_t id) {
  for (kk_stmt_t* s = g_stmts; s != NULL; s = s->next) if (s->id == id) return s;
  return NULL;
}

/* ------------------------------------------------------------ connections */

/* Open a database.  Returns a connection id, or a negative result code. */
static int64_t kk_sq_open(kk_string_t path, kk_context_t* _ctx) {
  kk_ssize_t len = 0;
  const char* p = kk_string_cbuf_borrow(path, &len, _ctx);
  char buf[4096];
  size_t n = (size_t)len < sizeof(buf) - 1 ? (size_t)len : sizeof(buf) - 1;
  memcpy(buf, p, n); buf[n] = 0;
  kk_string_drop(path, _ctx);

  sqlite3* db = NULL;
  int rc = sqlite3_open_v2(buf, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, NULL);
  if (rc != SQLITE_OK) {
    kk_sq_set_error(db, "cannot open database");
    if (db != NULL) sqlite3_close_v2(db);
    return -(int64_t)rc;
  }
  /* Foreign keys are off by default in sqlite; a service that declares them
     should have them enforced. */
  sqlite3_exec(db, "PRAGMA foreign_keys=ON", NULL, NULL, NULL);

  kk_db_t* d = (kk_db_t*)calloc(1, sizeof(kk_db_t));
  if (d == NULL) { sqlite3_close_v2(db); return -(int64_t)SQLITE_NOMEM; }
  d->id = g_sq_next_id++;
  d->db = db;
  d->next = g_dbs;
  g_dbs = d;
  return d->id;
}

/* Finalize every statement belonging to this connection, then close it.
   Idempotent: closing twice is not an error, which is what makes the scoped
   wrapper's release safe to run on any path. */
static int32_t kk_sq_close(int64_t dbid, kk_context_t* _ctx) {
  kk_unused(_ctx);
  kk_db_t** p = &g_dbs;
  while (*p != NULL && (*p)->id != dbid) p = &(*p)->next;
  if (*p == NULL) return 0;
  kk_db_t* d = *p;

  kk_stmt_t** sp = &g_stmts;
  while (*sp != NULL) {
    if ((*sp)->db_id == dbid) {
      kk_stmt_t* dead = *sp;
      *sp = dead->next;
      sqlite3_finalize(dead->stmt);
      free(dead);
    } else {
      sp = &(*sp)->next;
    }
  }

  *p = d->next;
  int rc = sqlite3_close_v2(d->db);
  free(d);
  return (rc == SQLITE_OK ? 0 : -(int32_t)rc);
}

/* Run one or more statements with no result rows (migrations, pragmas). */
static int32_t kk_sq_exec(int64_t dbid, kk_string_t sql, kk_context_t* _ctx) {
  kk_ssize_t len = 0;
  const char* p = kk_string_cbuf_borrow(sql, &len, _ctx);
  char* buf = (char*)malloc((size_t)len + 1);
  if (buf == NULL) { kk_string_drop(sql, _ctx); return -(int32_t)SQLITE_NOMEM; }
  memcpy(buf, p, (size_t)len); buf[len] = 0;
  kk_string_drop(sql, _ctx);

  kk_db_t* d = kk_sq_find_db(dbid);
  if (d == NULL) { free(buf); return -(int32_t)SQLITE_MISUSE; }
  char* err = NULL;
  int rc = sqlite3_exec(d->db, buf, NULL, NULL, &err);
  free(buf);
  if (rc != SQLITE_OK) {
    snprintf(g_sq_error, sizeof(g_sq_error), "%s", err != NULL ? err : "exec failed");
    if (err != NULL) sqlite3_free(err);
    return -(int32_t)rc;
  }
  return 0;
}

/* How long to wait when another connection holds the write lock. */
static int32_t kk_sq_busy_timeout(int64_t dbid, int32_t ms, kk_context_t* _ctx) {
  kk_unused(_ctx);
  kk_db_t* d = kk_sq_find_db(dbid);
  if (d == NULL) return -(int32_t)SQLITE_MISUSE;
  return (int32_t)sqlite3_busy_timeout(d->db, (int)ms);
}

static int64_t kk_sq_last_insert_id(int64_t dbid, kk_context_t* _ctx) {
  kk_unused(_ctx);
  kk_db_t* d = kk_sq_find_db(dbid);
  return (d == NULL) ? 0 : (int64_t)sqlite3_last_insert_rowid(d->db);
}

static int32_t kk_sq_changes(int64_t dbid, kk_context_t* _ctx) {
  kk_unused(_ctx);
  kk_db_t* d = kk_sq_find_db(dbid);
  return (d == NULL) ? 0 : (int32_t)sqlite3_changes(d->db);
}

/* ------------------------------------------------------------- statements */

static int64_t kk_sq_prepare(int64_t dbid, kk_string_t sql, kk_context_t* _ctx) {
  kk_ssize_t len = 0;
  const char* p = kk_string_cbuf_borrow(sql, &len, _ctx);
  char* buf = (char*)malloc((size_t)len + 1);
  if (buf == NULL) { kk_string_drop(sql, _ctx); return -(int64_t)SQLITE_NOMEM; }
  memcpy(buf, p, (size_t)len); buf[len] = 0;
  kk_string_drop(sql, _ctx);

  kk_db_t* d = kk_sq_find_db(dbid);
  if (d == NULL) { free(buf); return -(int64_t)SQLITE_MISUSE; }

  sqlite3_stmt* st = NULL;
  int rc = sqlite3_prepare_v2(d->db, buf, -1, &st, NULL);
  free(buf);
  if (rc != SQLITE_OK || st == NULL) {
    kk_sq_set_error(d->db, "cannot prepare statement");
    if (st != NULL) sqlite3_finalize(st);
    return -(int64_t)(rc == SQLITE_OK ? SQLITE_ERROR : rc);
  }
  kk_stmt_t* s = (kk_stmt_t*)calloc(1, sizeof(kk_stmt_t));
  if (s == NULL) { sqlite3_finalize(st); return -(int64_t)SQLITE_NOMEM; }
  s->id = g_sq_next_id++;
  s->stmt = st;
  s->db_id = dbid;
  s->next = g_stmts;
  g_stmts = s;
  return s->id;
}

/* Finalize.  Idempotent. */
static int32_t kk_sq_finalize(int64_t sid, kk_context_t* _ctx) {
  kk_unused(_ctx);
  kk_stmt_t** p = &g_stmts;
  while (*p != NULL && (*p)->id != sid) p = &(*p)->next;
  if (*p == NULL) return 0;
  kk_stmt_t* s = *p;
  *p = s->next;
  int rc = sqlite3_finalize(s->stmt);
  free(s);
  return (rc == SQLITE_OK ? 0 : -(int32_t)rc);
}

static int32_t kk_sq_reset(int64_t sid, kk_context_t* _ctx) {
  kk_unused(_ctx);
  kk_stmt_t* s = kk_sq_find_stmt(sid);
  if (s == NULL) return -(int32_t)SQLITE_MISUSE;
  sqlite3_clear_bindings(s->stmt);
  int rc = sqlite3_reset(s->stmt);
  return (rc == SQLITE_OK ? 0 : -(int32_t)rc);
}

/* Parameter indices are 1-based, as sqlite counts them. */
static int32_t kk_sq_bind_int(int64_t sid, int32_t idx, int64_t v, kk_context_t* _ctx) {
  kk_unused(_ctx);
  kk_stmt_t* s = kk_sq_find_stmt(sid);
  if (s == NULL) return -(int32_t)SQLITE_MISUSE;
  int rc = sqlite3_bind_int64(s->stmt, (int)idx, (sqlite3_int64)v);
  return (rc == SQLITE_OK ? 0 : -(int32_t)rc);
}

static int32_t kk_sq_bind_text(int64_t sid, int32_t idx, kk_string_t v, kk_context_t* _ctx) {
  kk_ssize_t len = 0;
  const char* p = kk_string_cbuf_borrow(v, &len, _ctx);
  kk_stmt_t* s = kk_sq_find_stmt(sid);
  int rc = SQLITE_MISUSE;
  if (s != NULL) {
    /* SQLITE_TRANSIENT: sqlite copies, so the Koka string may be released */
    rc = sqlite3_bind_text(s->stmt, (int)idx, p, (int)len, SQLITE_TRANSIENT);
  }
  kk_string_drop(v, _ctx);
  return (rc == SQLITE_OK ? 0 : -(int32_t)rc);
}

static int32_t kk_sq_bind_blob(int64_t sid, int32_t idx, kk_box_t vb, kk_context_t* _ctx) {
  kk_bytes_t v = kk_bytes_unbox(vb);
  kk_ssize_t len = 0;
  const uint8_t* p = kk_bytes_buf_borrow(v, &len, _ctx);
  kk_stmt_t* s = kk_sq_find_stmt(sid);
  int32_t r;
  if (s == NULL) {
    r = -(int32_t)SQLITE_MISUSE;
  } else {
    /* SQLITE_TRANSIENT: sqlite copies now, so the borrow need not outlive us */
    int rc = sqlite3_bind_blob(s->stmt, (int)idx, p, (int)len, SQLITE_TRANSIENT);
    r = (rc == SQLITE_OK ? 0 : -(int32_t)rc);
  }
  kk_bytes_drop(v, _ctx);
  return r;
}

static int32_t kk_sq_bind_null(int64_t sid, int32_t idx, kk_context_t* _ctx) {
  kk_unused(_ctx);
  kk_stmt_t* s = kk_sq_find_stmt(sid);
  if (s == NULL) return -(int32_t)SQLITE_MISUSE;
  int rc = sqlite3_bind_null(s->stmt, (int)idx);
  return (rc == SQLITE_OK ? 0 : -(int32_t)rc);
}

/* 1 = a row is available, 0 = done, negative = a result code. */
static int32_t kk_sq_step(int64_t sid, kk_context_t* _ctx) {
  kk_unused(_ctx);
  kk_stmt_t* s = kk_sq_find_stmt(sid);
  if (s == NULL) return -(int32_t)SQLITE_MISUSE;
  int rc = sqlite3_step(s->stmt);
  if (rc == SQLITE_ROW)  return 1;
  if (rc == SQLITE_DONE) return 0;
  kk_sq_set_error(sqlite3_db_handle(s->stmt), "step failed");
  return -(int32_t)rc;
}

static int32_t kk_sq_column_count(int64_t sid, kk_context_t* _ctx) {
  kk_unused(_ctx);
  kk_stmt_t* s = kk_sq_find_stmt(sid);
  return (s == NULL) ? 0 : (int32_t)sqlite3_column_count(s->stmt);
}

/* 1 = integer, 2 = float, 3 = text, 4 = blob, 5 = null */
static int32_t kk_sq_column_type(int64_t sid, int32_t col, kk_context_t* _ctx) {
  kk_unused(_ctx);
  kk_stmt_t* s = kk_sq_find_stmt(sid);
  if (s == NULL) return 5;
  return (int32_t)sqlite3_column_type(s->stmt, (int)col);
}

static kk_string_t kk_sq_column_name(int64_t sid, int32_t col, kk_context_t* _ctx) {
  kk_stmt_t* s = kk_sq_find_stmt(sid);
  if (s == NULL) return kk_string_empty();
  const char* n = sqlite3_column_name(s->stmt, (int)col);
  return kk_string_alloc_from_utf8(n == NULL ? "" : n, _ctx);
}

static int64_t kk_sq_column_int(int64_t sid, int32_t col, kk_context_t* _ctx) {
  kk_unused(_ctx);
  kk_stmt_t* s = kk_sq_find_stmt(sid);
  return (s == NULL) ? 0 : (int64_t)sqlite3_column_int64(s->stmt, (int)col);
}

static kk_string_t kk_sq_column_text(int64_t sid, int32_t col, kk_context_t* _ctx) {
  kk_stmt_t* s = kk_sq_find_stmt(sid);
  if (s == NULL) return kk_string_empty();
  const unsigned char* t = sqlite3_column_text(s->stmt, (int)col);
  int n = sqlite3_column_bytes(s->stmt, (int)col);
  if (t == NULL || n < 0) return kk_string_empty();
  return kk_string_alloc_dupn_valid_utf8((kk_ssize_t)n, t, _ctx);
}

static kk_box_t kk_sq_column_blob(int64_t sid, int32_t col, kk_context_t* _ctx) {
  kk_stmt_t* s = kk_sq_find_stmt(sid);
  if (s == NULL) return kk_bytes_box(kk_bytes_empty());
  const void* b = sqlite3_column_blob(s->stmt, (int)col);
  int n = sqlite3_column_bytes(s->stmt, (int)col);
  if (b == NULL || n <= 0) return kk_bytes_box(kk_bytes_empty());
  return kk_bytes_box(kk_bytes_alloc_dupn((kk_ssize_t)n, (const uint8_t*)b, _ctx));
}

static kk_string_t kk_sq_last_error(kk_context_t* _ctx) {
  return kk_string_alloc_from_utf8(g_sq_error, _ctx);
}

static kk_string_t kk_sq_version(kk_context_t* _ctx) {
  return kk_string_alloc_from_utf8(sqlite3_libversion(), _ctx);
}

/* How many statements and connections are still open.  Used by the tests to
   assert that nothing leaks; a service does not need it. */
static int32_t kk_sq_open_statements(kk_context_t* _ctx) {
  kk_unused(_ctx);
  int n = 0;
  for (kk_stmt_t* s = g_stmts; s != NULL; s = s->next) n++;
  return (int32_t)n;
}

static int32_t kk_sq_open_connections(kk_context_t* _ctx) {
  kk_unused(_ctx);
  int n = 0;
  for (kk_db_t* d = g_dbs; d != NULL; d = d->next) n++;
  return (int32_t)n;
}
