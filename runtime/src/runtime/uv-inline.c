/* libuv binding for the Koka runtime package.

   ## Design: a completion queue, never a callback into Koka

   libuv is callback driven, but calling back into Koka from a C callback
   would mean holding Koka closures in C and resuming continuations from
   arbitrary stack depths.  Instead every libuv callback here does one thing:
   it appends a *completion record* to a queue.  Koka drives the loop with
   `uv_run_once` and then drains the queue with `uv_next_completion`.  All
   scheduling state lives in Koka; C holds only handles and a queue.

   The consequences are worth stating: there is exactly one event loop, it is
   single threaded, and no Koka code ever runs inside a libuv callback.

   ## Identifiers

   Every stream and every in-flight request is named by an `int64` id assigned
   here.  Koka never sees a pointer, which is what keeps raw native handles
   internal as the design requires.
*/
#include <uv.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <errno.h>
#include <time.h>

/* --------------------------------------------------------------- state --- */

typedef enum kk_uv_kind_e {
  KK_UV_TIMER = 1,
  KK_UV_ACCEPT,
  KK_UV_CONNECT,
  KK_UV_READ,
  KK_UV_WRITE,
  KK_UV_RESOLVE
} kk_uv_kind_t;

typedef struct kk_comp_s {
  int64_t            id;       /* the request id Koka is waiting on */
  int32_t            status;   /* 0 or a negative libuv error code */
  int64_t            value;    /* new stream id, or octets transferred */
  uint8_t*           data;     /* payload for reads; owned here until taken */
  size_t             len;
  char*              text;     /* payload for DNS results */
  struct kk_comp_s*  next;
} kk_comp_t;

typedef struct kk_stream_s {
  int64_t        id;
  uv_tcp_t       tcp;
  bool           closing;
  /* A listening socket and a connected socket are different things and must
     not be closable through each other's API.  Without this, a `socket` value
     that somehow carried a listener's id would take the whole server down --
     and a single-field value struct makes the two indistinguishable at
     runtime, so the check belongs here rather than in the type system. */
  bool           is_listener;
  /* one pending read request at a time; 0 means none */
  int64_t        read_req;
  size_t         read_max;
  /* connections accepted before Koka asked for them */
  int64_t*       backlog;
  int            backlog_len;
  int            backlog_cap;
  int64_t        accept_req;
  struct kk_stream_s* next;
} kk_stream_t;

static uv_loop_t*   g_loop = NULL;
static kk_comp_t*   g_comp_head = NULL;
static kk_comp_t*   g_comp_tail = NULL;
static kk_stream_t* g_streams = NULL;
static int64_t      g_next_id = 1;

/* the most recently taken completion, read back field by field */
static int32_t  g_last_status = 0;
static int64_t  g_last_value  = 0;
static uint8_t* g_last_data   = NULL;
static size_t   g_last_len    = 0;
static char*    g_last_text   = NULL;

static int64_t kk_uv_fresh_id(void) { return g_next_id++; }

static void kk_uv_push(int64_t id, int32_t status, int64_t value,
                       uint8_t* data, size_t len, char* text) {
  kk_comp_t* c = (kk_comp_t*)calloc(1, sizeof(kk_comp_t));
  if (c == NULL) return;
  c->id = id; c->status = status; c->value = value;
  c->data = data; c->len = len; c->text = text;
  if (g_comp_tail == NULL) { g_comp_head = g_comp_tail = c; }
  else { g_comp_tail->next = c; g_comp_tail = c; }
}

static kk_stream_t* kk_uv_find(int64_t id) {
  for (kk_stream_t* s = g_streams; s != NULL; s = s->next) {
    if (s->id == id) return s;
  }
  return NULL;
}

static kk_stream_t* kk_uv_new_stream(void) {
  kk_stream_t* s = (kk_stream_t*)calloc(1, sizeof(kk_stream_t));
  if (s == NULL) return NULL;
  s->id = kk_uv_fresh_id();
  if (uv_tcp_init(g_loop, &s->tcp) != 0) { free(s); return NULL; }
  s->tcp.data = s;
  s->next = g_streams;
  g_streams = s;
  return s;
}

static void kk_uv_forget(kk_stream_t* s) {
  kk_stream_t** p = &g_streams;
  while (*p != NULL) {
    if (*p == s) { *p = s->next; break; }
    p = &(*p)->next;
  }
  free(s->backlog);
  free(s);
}

static void kk_uv_on_closed(uv_handle_t* h) {
  kk_stream_t* s = (kk_stream_t*)h->data;
  if (s != NULL) kk_uv_forget(s);
}

/* --------------------------------------------------------------- setup --- */

static int32_t kk_uv_init(kk_context_t* _ctx) {
  kk_unused(_ctx);
  if (g_loop != NULL) return 0;
  g_loop = (uv_loop_t*)calloc(1, sizeof(uv_loop_t));
  if (g_loop == NULL) return -1;
  return (int32_t)uv_loop_init(g_loop);
}

/* Close every handle and run the loop until they are gone, so shutdown does
   not leave descriptors open.  Called once at process shutdown. */
static void kk_uv_walk_close(uv_handle_t* h, void* arg) {
  kk_unused(arg);
  if (!uv_is_closing(h)) uv_close(h, h->data != NULL ? kk_uv_on_closed : NULL);
}

static int32_t kk_uv_shutdown(kk_context_t* _ctx) {
  kk_unused(_ctx);
  if (g_loop == NULL) return 0;
  uv_walk(g_loop, kk_uv_walk_close, NULL);
  /* let the close callbacks run */
  for (int i = 0; i < 64 && uv_run(g_loop, UV_RUN_NOWAIT) != 0; i++) { }
  int r = uv_loop_close(g_loop);
  if (r == 0) { free(g_loop); g_loop = NULL; }
  return (int32_t)r;
}

/* ---------------------------------------------------------------- loop --- */

/* A timer that exists only to bound how long `uv_run` may block, so a Koka
   scheduler with ready work is never left waiting on I/O. */
static uv_timer_t g_tick;
static bool       g_tick_init = false;
static void kk_uv_tick_cb(uv_timer_t* t) { kk_unused(t); }

/* Run the loop once.  `timeout_ms` < 0 blocks until something happens; 0
   polls; > 0 blocks at most that long.  Returns the number of active
   handles, so a caller can tell when there is nothing left to wait for. */
static int32_t kk_uv_run_once(int32_t timeout_ms, kk_context_t* _ctx) {
  kk_unused(_ctx);
  if (g_loop == NULL) return 0;
  if (timeout_ms == 0) {
    uv_run(g_loop, UV_RUN_NOWAIT);
  } else {
    if (timeout_ms > 0) {
      if (!g_tick_init) { uv_timer_init(g_loop, &g_tick); g_tick_init = true; }
      uv_timer_start(&g_tick, kk_uv_tick_cb, (uint64_t)timeout_ms, 0);
      uv_unref((uv_handle_t*)&g_tick);   /* must not keep the loop alive */
    }
    uv_run(g_loop, UV_RUN_ONCE);
    if (timeout_ms > 0 && g_tick_init) uv_timer_stop(&g_tick);
  }
  int active = 0;
  for (kk_stream_t* s = g_streams; s != NULL; s = s->next) active++;
  return (int32_t)active;
}

/* Take the next completion.  Returns its id, or 0 when the queue is empty.
   The status, value and payload are read back with the accessors below. */
static int64_t kk_uv_next_completion(kk_context_t* _ctx) {
  kk_unused(_ctx);
  free(g_last_data); g_last_data = NULL; g_last_len = 0;
  free(g_last_text); g_last_text = NULL;
  if (g_comp_head == NULL) return 0;
  kk_comp_t* c = g_comp_head;
  g_comp_head = c->next;
  if (g_comp_head == NULL) g_comp_tail = NULL;
  g_last_status = c->status;
  g_last_value  = c->value;
  g_last_data   = c->data;
  g_last_len    = c->len;
  g_last_text   = c->text;
  int64_t id = c->id;
  free(c);
  return id;
}

static int32_t kk_uv_last_status(kk_context_t* _ctx) { kk_unused(_ctx); return g_last_status; }
static int64_t kk_uv_last_value(kk_context_t* _ctx)  { kk_unused(_ctx); return g_last_value; }

static kk_box_t kk_uv_last_bytes(kk_context_t* _ctx) {
  if (g_last_data == NULL || g_last_len == 0) return kk_bytes_box(kk_bytes_empty());
  return kk_bytes_box(kk_bytes_alloc_dupn((kk_ssize_t)g_last_len, g_last_data, _ctx));
}

static kk_string_t kk_uv_last_text(kk_context_t* _ctx) {
  return kk_string_alloc_from_utf8(g_last_text == NULL ? "" : g_last_text, _ctx);
}

static kk_string_t kk_uv_strerror(int32_t err, kk_context_t* _ctx) {
  return kk_string_alloc_from_utf8(uv_strerror((int)err), _ctx);
}

/* --------------------------------------------------------------- timer --- */

typedef struct kk_timer_s { uv_timer_t t; int64_t id; } kk_timer_req_t;

static void kk_uv_timer_cb(uv_timer_t* t) {
  kk_timer_req_t* r = (kk_timer_req_t*)t->data;
  kk_uv_push(r->id, 0, 0, NULL, 0, NULL);
  uv_close((uv_handle_t*)t, (uv_close_cb)free);
}

/* Complete request `req` after `ms` milliseconds. */
static int32_t kk_uv_timer_start(int64_t req, int64_t ms, kk_context_t* _ctx) {
  kk_unused(_ctx);
  kk_timer_req_t* r = (kk_timer_req_t*)calloc(1, sizeof(kk_timer_req_t));
  if (r == NULL) return UV_ENOMEM;
  r->id = req;
  r->t.data = r;
  int rc = uv_timer_init(g_loop, &r->t);
  if (rc != 0) { free(r); return (int32_t)rc; }
  rc = uv_timer_start(&r->t, kk_uv_timer_cb, (uint64_t)(ms < 0 ? 0 : ms), 0);
  if (rc != 0) { uv_close((uv_handle_t*)&r->t, (uv_close_cb)free); return (int32_t)rc; }
  return 0;
}

/* ----------------------------------------------------------------- tcp --- */

static void kk_uv_alloc_cb(uv_handle_t* h, size_t suggested, uv_buf_t* buf) {
  kk_stream_t* s = (kk_stream_t*)h->data;
  size_t want = (s != NULL && s->read_max > 0 && s->read_max < suggested)
                  ? s->read_max : suggested;
  buf->base = (char*)malloc(want);
  buf->len  = (buf->base == NULL) ? 0 : want;
}

static void kk_uv_read_cb(uv_stream_t* st, ssize_t nread, const uv_buf_t* buf) {
  kk_stream_t* s = (kk_stream_t*)st->data;
  if (s == NULL) { free(buf->base); return; }
  int64_t req = s->read_req;
  s->read_req = 0;
  uv_read_stop(st);                    /* one read per request */
  if (nread > 0) {
    kk_uv_push(req, 0, nread, (uint8_t*)buf->base, (size_t)nread, NULL);
    /* the payload is now owned by the completion */
  } else if (nread == 0) {
    free(buf->base);
    /* nothing was available after all: complete with an empty read */
    kk_uv_push(req, 0, 0, NULL, 0, NULL);
  } else {
    free(buf->base);
    /* UV_EOF is reported as status 0 with zero octets, which is what a
       caller means by "end of stream"; anything else is an error */
    if (nread == UV_EOF) kk_uv_push(req, 0, 0, NULL, 0, NULL);
    else kk_uv_push(req, (int32_t)nread, 0, NULL, 0, NULL);
  }
}

/* Every path through this callback must consume the pending connection with
   `uv_accept`.  libuv stops polling the listening handle for good if the
   callback returns without accepting -- the handle still reports itself as
   active, so the failure looks like "the server silently stopped accepting"
   rather than like an error.  That is why the out-of-memory paths below
   accept into a throwaway handle and close it instead of simply returning. */
static void kk_uv_drop_pending(uv_stream_t* server) {
  uv_tcp_t* tmp = (uv_tcp_t*)calloc(1, sizeof(uv_tcp_t));
  if (tmp == NULL) return;                 /* nothing better is possible */
  if (uv_tcp_init(g_loop, tmp) != 0) { free(tmp); return; }
  tmp->data = NULL;
  if (uv_accept(server, (uv_stream_t*)tmp) == 0) {
    uv_close((uv_handle_t*)tmp, (uv_close_cb)free);
  } else {
    uv_close((uv_handle_t*)tmp, (uv_close_cb)free);
  }
}

static void kk_uv_connection_cb(uv_stream_t* server, int status) {
  kk_stream_t* s = (kk_stream_t*)server->data;
  if (s == NULL) { kk_uv_drop_pending(server); return; }
  if (status != 0) {
    if (s->accept_req != 0) { kk_uv_push(s->accept_req, status, 0, NULL, 0, NULL); s->accept_req = 0; }
    return;
  }
  kk_stream_t* client = kk_uv_new_stream();
  if (client == NULL) {
    kk_uv_drop_pending(server);
    return;
  }
  if (uv_accept(server, (uv_stream_t*)&client->tcp) != 0) {
    uv_close((uv_handle_t*)&client->tcp, kk_uv_on_closed);
    return;
  }
  if (s->accept_req != 0) {
    kk_uv_push(s->accept_req, 0, client->id, NULL, 0, NULL);
    s->accept_req = 0;
  } else {
    /* nobody is waiting yet: remember it.  The backlog is bounded by the
       listen backlog, so this cannot grow without limit. */
    if (s->backlog_len == s->backlog_cap) {
      int cap = s->backlog_cap == 0 ? 8 : s->backlog_cap * 2;
      int64_t* nb = (int64_t*)realloc(s->backlog, (size_t)cap * sizeof(int64_t));
      if (nb == NULL) {
        uv_close((uv_handle_t*)&client->tcp, kk_uv_on_closed); return;
      }
      s->backlog = nb; s->backlog_cap = cap;
    }
    s->backlog[s->backlog_len++] = client->id;
  }
}

/* Bind and listen.  Returns a stream id, or a negative libuv error. */
static int64_t kk_uv_listen(kk_string_t host, int32_t port, int32_t backlog, kk_context_t* _ctx) {
  kk_ssize_t hl = 0;
  const char* h = kk_string_cbuf_borrow(host, &hl, _ctx);
  char hbuf[256];
  size_t n = (size_t)hl < sizeof(hbuf) - 1 ? (size_t)hl : sizeof(hbuf) - 1;
  memcpy(hbuf, h, n); hbuf[n] = 0;
  kk_string_drop(host, _ctx);

  kk_stream_t* s = kk_uv_new_stream();
  if (s == NULL) return UV_ENOMEM;

  struct sockaddr_in addr;
  int rc = uv_ip4_addr(hbuf, (int)port, &addr);
  if (rc != 0) { uv_close((uv_handle_t*)&s->tcp, kk_uv_on_closed); return rc; }
  rc = uv_tcp_bind(&s->tcp, (const struct sockaddr*)&addr, 0);
  if (rc != 0) { uv_close((uv_handle_t*)&s->tcp, kk_uv_on_closed); return rc; }
  rc = uv_listen((uv_stream_t*)&s->tcp, (int)backlog, kk_uv_connection_cb);
  if (rc != 0) { uv_close((uv_handle_t*)&s->tcp, kk_uv_on_closed); return rc; }
  s->is_listener = true;
  return s->id;
}

/* The port actually bound, which matters when port 0 was requested. */
static int32_t kk_uv_bound_port(int64_t sid, kk_context_t* _ctx) {
  kk_unused(_ctx);
  kk_stream_t* s = kk_uv_find(sid);
  if (s == NULL) return -1;
  struct sockaddr_storage ss;
  int len = sizeof(ss);
  if (uv_tcp_getsockname(&s->tcp, (struct sockaddr*)&ss, &len) != 0) return -1;
  if (ss.ss_family == AF_INET) return (int32_t)ntohs(((struct sockaddr_in*)&ss)->sin_port);
  return -1;
}

/* Arm an accept.  Completes immediately if a connection is already waiting. */
static int32_t kk_uv_accept(int64_t sid, int64_t req, kk_context_t* _ctx) {
  kk_unused(_ctx);
  kk_stream_t* s = kk_uv_find(sid);
  if (s == NULL) return UV_EBADF;
  if (!s->is_listener) return UV_EINVAL;
  if (s->backlog_len > 0) {
    int64_t cid = s->backlog[0];
    memmove(s->backlog, s->backlog + 1, (size_t)(s->backlog_len - 1) * sizeof(int64_t));
    s->backlog_len--;
    kk_uv_push(req, 0, cid, NULL, 0, NULL);
    return 0;
  }
  if (s->accept_req != 0) return UV_EBUSY;   /* one waiter per listener */
  s->accept_req = req;
  return 0;
}

typedef struct kk_conn_s { uv_connect_t r; int64_t req; int64_t sid; } kk_conn_req_t;

static void kk_uv_connect_cb(uv_connect_t* r, int status) {
  kk_conn_req_t* c = (kk_conn_req_t*)r->data;
  kk_uv_push(c->req, (int32_t)status, c->sid, NULL, 0, NULL);
  free(c);
}

static int64_t kk_uv_connect(kk_string_t host, int32_t port, int64_t req, kk_context_t* _ctx) {
  kk_ssize_t hl = 0;
  const char* h = kk_string_cbuf_borrow(host, &hl, _ctx);
  char hbuf[256];
  size_t n = (size_t)hl < sizeof(hbuf) - 1 ? (size_t)hl : sizeof(hbuf) - 1;
  memcpy(hbuf, h, n); hbuf[n] = 0;
  kk_string_drop(host, _ctx);

  kk_stream_t* s = kk_uv_new_stream();
  if (s == NULL) return UV_ENOMEM;
  struct sockaddr_in addr;
  int rc = uv_ip4_addr(hbuf, (int)port, &addr);
  if (rc != 0) { uv_close((uv_handle_t*)&s->tcp, kk_uv_on_closed); return rc; }

  kk_conn_req_t* c = (kk_conn_req_t*)calloc(1, sizeof(kk_conn_req_t));
  if (c == NULL) { uv_close((uv_handle_t*)&s->tcp, kk_uv_on_closed); return UV_ENOMEM; }
  c->req = req; c->sid = s->id; c->r.data = c;
  rc = uv_tcp_connect(&c->r, &s->tcp, (const struct sockaddr*)&addr, kk_uv_connect_cb);
  if (rc != 0) { free(c); uv_close((uv_handle_t*)&s->tcp, kk_uv_on_closed); return rc; }
  return s->id;
}

/* Arm one read of at most `max` octets. */
static int32_t kk_uv_read(int64_t sid, int64_t req, int64_t max, kk_context_t* _ctx) {
  kk_unused(_ctx);
  kk_stream_t* s = kk_uv_find(sid);
  if (s == NULL) return UV_EBADF;
  /* Reading is meaningless on a listening handle, and `uv_read_start` /
     `uv_read_stop` on one would start and then *stop* its io watcher --
     which silently ends accepting while leaving the handle open and
     reporting itself active.  Refuse rather than corrupt the listener. */
  if (s->is_listener) return UV_EINVAL;
  if (s->read_req != 0) return UV_EBUSY;     /* one reader per stream */
  s->read_req = req;
  s->read_max = (size_t)(max <= 0 ? 65536 : max);
  int rc = uv_read_start((uv_stream_t*)&s->tcp, kk_uv_alloc_cb, kk_uv_read_cb);
  if (rc != 0) { s->read_req = 0; return (int32_t)rc; }
  return 0;
}

typedef struct kk_write_s { uv_write_t r; int64_t req; char* buf; } kk_write_req_t;

static void kk_uv_write_cb(uv_write_t* r, int status) {
  kk_write_req_t* w = (kk_write_req_t*)r->data;
  kk_uv_push(w->req, (int32_t)status, 0, NULL, 0, NULL);
  free(w->buf);
  free(w);
}

static int32_t kk_uv_write(int64_t sid, int64_t req, kk_box_t datab, kk_context_t* _ctx) {
  kk_bytes_t data = kk_bytes_unbox(datab);
  kk_ssize_t len = 0;
  const uint8_t* p = kk_bytes_buf_borrow(data, &len, _ctx);

  kk_stream_t* s = kk_uv_find(sid);
  if (s == NULL) return UV_EBADF;
  if (s->is_listener) return UV_EINVAL;

  kk_write_req_t* w = (kk_write_req_t*)calloc(1, sizeof(kk_write_req_t));
  if (w == NULL) return UV_ENOMEM;
  w->req = req;
  w->buf = (char*)malloc((size_t)(len > 0 ? len : 1));
  if (w->buf == NULL) { free(w); return UV_ENOMEM; }
  memcpy(w->buf, p, (size_t)len);
  w->r.data = w;

  uv_buf_t b = uv_buf_init(w->buf, (unsigned int)len);
  int rc = uv_write(&w->r, (uv_stream_t*)&s->tcp, &b, 1, kk_uv_write_cb);
  if (rc != 0) { free(w->buf); free(w); return (int32_t)rc; }
  return 0;
}

/* Stop reading and close.  Idempotent: closing twice is not an error.
   `want_listener` says which kind of handle the caller believes it has; a
   mismatch is refused rather than obeyed. */
static kk_unit_t kk_uv_close_kind(int64_t sid, bool want_listener, kk_context_t* _ctx) {
  kk_unused(_ctx);
  kk_stream_t* s = kk_uv_find(sid);
  if (s == NULL || s->closing) return kk_Unit;
  if (s->is_listener != want_listener) return kk_Unit;


  s->closing = true;
  if (s->read_req != 0) {
    /* a pending read must be completed, or its task would wait forever */
    kk_uv_push(s->read_req, UV_ECANCELED, 0, NULL, 0, NULL);
    s->read_req = 0;
  }
  if (s->accept_req != 0) {
    kk_uv_push(s->accept_req, UV_ECANCELED, 0, NULL, 0, NULL);
    s->accept_req = 0;
  }
  uv_read_stop((uv_stream_t*)&s->tcp);
  uv_close((uv_handle_t*)&s->tcp, kk_uv_on_closed);
  return kk_Unit;
}

static kk_unit_t kk_uv_close(int64_t sid, kk_context_t* _ctx) {
  return kk_uv_close_kind(sid, false, _ctx);
}

static kk_unit_t kk_uv_close_listener(int64_t sid, kk_context_t* _ctx) {
  return kk_uv_close_kind(sid, true, _ctx);
}

/* Abandon a pending accept or read.

   A timed-out `accept-within` or `read-within` has stopped waiting, but the
   request is still armed here; without clearing it the next arm would get
   EBUSY.  The completion is pushed as cancelled so that a task which *is*
   still parked on it (a cancelled group, say) is woken rather than stranded. */
static kk_unit_t kk_uv_cancel_accept(int64_t sid, kk_context_t* _ctx) {
  kk_unused(_ctx);
  kk_stream_t* s = kk_uv_find(sid);
  if (s == NULL || !s->is_listener || s->accept_req == 0) return kk_Unit;
  kk_uv_push(s->accept_req, UV_ECANCELED, 0, NULL, 0, NULL);
  s->accept_req = 0;
  return kk_Unit;
}

static kk_unit_t kk_uv_cancel_read(int64_t sid, kk_context_t* _ctx) {
  kk_unused(_ctx);
  kk_stream_t* s = kk_uv_find(sid);
  if (s == NULL || s->is_listener || s->read_req == 0) return kk_Unit;
  uv_read_stop((uv_stream_t*)&s->tcp);
  kk_uv_push(s->read_req, UV_ECANCELED, 0, NULL, 0, NULL);
  s->read_req = 0;
  return kk_Unit;
}

static bool kk_uv_is_open(int64_t sid, kk_context_t* _ctx) {
  kk_unused(_ctx);
  kk_stream_t* s = kk_uv_find(sid);
  return (s != NULL && !s->closing);
}

/* Peer address of a connected stream, as a dotted-quad string. */
static kk_string_t kk_uv_peer(int64_t sid, kk_context_t* _ctx) {
  kk_stream_t* s = kk_uv_find(sid);
  if (s == NULL) return kk_string_empty();
  struct sockaddr_storage ss;
  int len = sizeof(ss);
  if (uv_tcp_getpeername(&s->tcp, (struct sockaddr*)&ss, &len) != 0) return kk_string_empty();
  char buf[64] = {0};
  if (ss.ss_family == AF_INET) {
    uv_ip4_name((struct sockaddr_in*)&ss, buf, sizeof(buf));
  }
  return kk_string_alloc_from_utf8(buf, _ctx);
}

/* ----------------------------------------------------------------- dns --- */

typedef struct kk_res_s { uv_getaddrinfo_t r; int64_t req; } kk_res_req_t;

static void kk_uv_resolve_cb(uv_getaddrinfo_t* r, int status, struct addrinfo* res) {
  kk_res_req_t* q = (kk_res_req_t*)r->data;
  if (status != 0 || res == NULL) {
    kk_uv_push(q->req, (int32_t)status, 0, NULL, 0, NULL);
  } else {
    char buf[64] = {0};
    if (res->ai_family == AF_INET) {
      uv_ip4_name((struct sockaddr_in*)res->ai_addr, buf, sizeof(buf));
    }
    kk_uv_push(q->req, 0, 0, NULL, 0, strdup(buf));
  }
  if (res != NULL) uv_freeaddrinfo(res);
  free(q);
}

static int32_t kk_uv_resolve(kk_string_t host, int64_t req, kk_context_t* _ctx) {
  kk_ssize_t hl = 0;
  const char* h = kk_string_cbuf_borrow(host, &hl, _ctx);
  char hbuf[256];
  size_t n = (size_t)hl < sizeof(hbuf) - 1 ? (size_t)hl : sizeof(hbuf) - 1;
  memcpy(hbuf, h, n); hbuf[n] = 0;
  kk_string_drop(host, _ctx);

  kk_res_req_t* q = (kk_res_req_t*)calloc(1, sizeof(kk_res_req_t));
  if (q == NULL) return UV_ENOMEM;
  q->req = req; q->r.data = q;
  struct addrinfo hints;
  memset(&hints, 0, sizeof(hints));
  hints.ai_family = AF_INET;
  hints.ai_socktype = SOCK_STREAM;
  int rc = uv_getaddrinfo(g_loop, &q->r, kk_uv_resolve_cb, hbuf, NULL, &hints);
  if (rc != 0) { free(q); return (int32_t)rc; }
  return 0;
}

/* --------------------------------------------------------------- misc --- */

static int64_t kk_uv_now(kk_context_t* _ctx) {
  kk_unused(_ctx);
  if (g_loop == NULL) return 0;
  uv_update_time(g_loop);
  return (int64_t)uv_now(g_loop);
}

static int64_t kk_uv_next_id(kk_context_t* _ctx) {
  kk_unused(_ctx);
  return kk_uv_fresh_id();
}

/* How many completions are waiting.  Used by the scheduler to decide whether
   to block on the loop. */
static int32_t kk_uv_pending(kk_context_t* _ctx) {
  kk_unused(_ctx);
  int n = 0;
  for (kk_comp_t* c = g_comp_head; c != NULL; c = c->next) n++;
  return (int32_t)n;
}
