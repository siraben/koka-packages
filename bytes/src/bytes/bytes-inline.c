/* C support for `bytes/bytes`.

   Immutable sequences are `kk_bytes_t`, boxed into Koka as `any`.  The builder
   is a plain malloc'd growable buffer wrapped in a raw C pointer box with a
   free function, so the runtime releases it when the builder value is dropped
   even if `finish` is never called.
*/
#include <string.h>
#include <stdlib.h>
#include <stdint.h>
#include <stdio.h>

/* ---------------------------------------------------------------- immutable */

static kk_box_t kk_bytesx_empty(kk_context_t* _ctx) {
  return kk_bytes_box(kk_bytes_empty());
}

static kk_box_t kk_bytesx_of_string(kk_string_t s, kk_context_t* _ctx) {
  kk_ssize_t len = 0;
  const uint8_t* p = (const uint8_t*)kk_string_cbuf_borrow(s, &len, _ctx);
  kk_bytes_t b = kk_bytes_alloc_dupn(len, p, _ctx);
  kk_string_drop(s, _ctx);
  return kk_bytes_box(b);
}

static kk_box_t kk_bytesx_replicate(int32_t v, kk_ssize_t n, kk_context_t* _ctx) {
  if (n <= 0) return kk_bytes_box(kk_bytes_empty());
  uint8_t* buf = NULL;
  kk_bytes_t b = kk_bytes_alloc_buf(n, &buf, _ctx);
  memset(buf, (int)(((uint32_t)v) & 0xFF), (size_t)n);
  return kk_bytes_box(b);
}

static kk_ssize_t kk_bytesx_length(kk_box_t bb, kk_context_t* _ctx) {
  kk_bytes_t b = kk_bytes_unbox(bb);
  kk_ssize_t n = kk_bytes_len_borrow(b, _ctx);
  kk_bytes_drop(b, _ctx);
  return n;
}

static int32_t kk_bytesx_at(kk_box_t bb, kk_ssize_t i, kk_context_t* _ctx) {
  kk_bytes_t b = kk_bytes_unbox(bb);
  kk_ssize_t len = 0;
  const uint8_t* p = kk_bytes_buf_borrow(b, &len, _ctx);
  int32_t r = (i < 0 || i >= len ? 0 : (int32_t)p[i]);
  kk_bytes_drop(b, _ctx);
  return r;
}

static kk_box_t kk_bytesx_cat(kk_box_t ab, kk_box_t bb, kk_context_t* _ctx) {
  kk_bytes_t a = kk_bytes_unbox(ab);
  kk_bytes_t b = kk_bytes_unbox(bb);
  return kk_bytes_box(kk_bytes_cat(a, b, _ctx));
}

static kk_box_t kk_bytesx_slice(kk_box_t bb, kk_ssize_t start, kk_ssize_t len, kk_context_t* _ctx) {
  kk_bytes_t b = kk_bytes_unbox(bb);
  kk_ssize_t n = 0;
  const uint8_t* p = kk_bytes_buf_borrow(b, &n, _ctx);
  if (start < 0) start = 0;
  if (start > n) start = n;
  if (len < 0 || start + len > n) len = n - start;
  kk_bytes_t out = kk_bytes_alloc_dupn(len, p + start, _ctx);
  kk_bytes_drop(b, _ctx);
  return kk_bytes_box(out);
}

static kk_ssize_t kk_bytesx_index_of(kk_box_t bb, kk_box_t sb, kk_ssize_t from, kk_context_t* _ctx) {
  kk_bytes_t b = kk_bytes_unbox(bb);
  kk_bytes_t s = kk_bytes_unbox(sb);
  kk_ssize_t n = 0, m = 0;
  const uint8_t* p = kk_bytes_buf_borrow(b, &n, _ctx);
  const uint8_t* q = kk_bytes_buf_borrow(s, &m, _ctx);
  if (from < 0) from = 0;
  kk_ssize_t r = -1;
  if (m == 0) {
    r = (from <= n ? from : -1);
  } else if (m <= n) {
    for (kk_ssize_t i = from; i + m <= n; i++) {
      if (memcmp(p + i, q, (size_t)m) == 0) { r = i; break; }
    }
  }
  kk_bytes_drop(b, _ctx);
  kk_bytes_drop(s, _ctx);
  return r;
}

/* Strict UTF-8 validation: rejects overlong forms, surrogates, and anything
   above U+10FFFF, so a validated sequence really is a well-formed string. */
static bool kk_bytesx_is_utf8(kk_box_t bb, kk_context_t* _ctx) {
  kk_bytes_t b = kk_bytes_unbox(bb);
  kk_ssize_t n = 0;
  const uint8_t* p = kk_bytes_buf_borrow(b, &n, _ctx);
  kk_ssize_t i = 0;
  bool ok = true;
  while (ok && i < n) {
    uint8_t c = p[i];
    if (c < 0x80) { i++; continue; }
    kk_ssize_t extra;
    uint32_t cp;
    if ((c & 0xE0) == 0xC0)      { extra = 1; cp = c & 0x1F; }
    else if ((c & 0xF0) == 0xE0) { extra = 2; cp = c & 0x0F; }
    else if ((c & 0xF8) == 0xF0) { extra = 3; cp = c & 0x07; }
    else { ok = false; break; }
    if (i + extra >= n) { ok = false; break; }
    for (kk_ssize_t k = 1; k <= extra; k++) {
      uint8_t cc = p[i + k];
      if ((cc & 0xC0) != 0x80) { ok = false; break; }
      cp = (cp << 6) | (uint32_t)(cc & 0x3F);
    }
    if (!ok) break;
    if (extra == 1 && cp < 0x80) ok = false;           /* overlong */
    else if (extra == 2 && cp < 0x800) ok = false;     /* overlong */
    else if (extra == 3 && cp < 0x10000) ok = false;   /* overlong */
    else if (cp > 0x10FFFF) ok = false;                /* out of range */
    else if (cp >= 0xD800 && cp <= 0xDFFF) ok = false; /* surrogate */
    i += extra + 1;
  }
  kk_bytes_drop(b, _ctx);
  return ok;
}

/* Decode replacing every invalid sequence with U+FFFD (EF BF BD). */
static kk_string_t kk_bytesx_to_string_lossy(kk_box_t bb, kk_context_t* _ctx) {
  kk_bytes_t b = kk_bytes_unbox(bb);
  kk_ssize_t n = 0;
  const uint8_t* p = kk_bytes_buf_borrow(b, &n, _ctx);

  /* worst case: every octet becomes a 3-byte replacement character */
  uint8_t* out = (uint8_t*)malloc((size_t)(n * 3 + 1));
  if (out == NULL) { kk_bytes_drop(b, _ctx); return kk_string_empty(); }
  kk_ssize_t o = 0, i = 0;
  while (i < n) {
    uint8_t c = p[i];
    kk_ssize_t extra;
    uint32_t cp;
    bool ok = true;
    if (c < 0x80)                { out[o++] = c; i++; continue; }
    else if ((c & 0xE0) == 0xC0) { extra = 1; cp = c & 0x1F; }
    else if ((c & 0xF0) == 0xE0) { extra = 2; cp = c & 0x0F; }
    else if ((c & 0xF8) == 0xF0) { extra = 3; cp = c & 0x07; }
    else                         { extra = 0; cp = 0; ok = false; }
    if (ok && i + extra < n) {
      for (kk_ssize_t k = 1; k <= extra; k++) {
        uint8_t cc = p[i + k];
        if ((cc & 0xC0) != 0x80) { ok = false; break; }
        cp = (cp << 6) | (uint32_t)(cc & 0x3F);
      }
      if (ok) {
        if (extra == 1 && cp < 0x80) ok = false;
        else if (extra == 2 && cp < 0x800) ok = false;
        else if (extra == 3 && cp < 0x10000) ok = false;
        else if (cp > 0x10FFFF) ok = false;
        else if (cp >= 0xD800 && cp <= 0xDFFF) ok = false;
      }
    } else if (ok) {
      ok = false;   /* truncated at the end of input */
    }
    if (ok) {
      memcpy(out + o, p + i, (size_t)(extra + 1));
      o += extra + 1;
      i += extra + 1;
    } else {
      out[o++] = 0xEF; out[o++] = 0xBF; out[o++] = 0xBD;
      i++;            /* resynchronise one octet at a time */
    }
  }
  out[o] = 0;
  kk_string_t s = kk_string_alloc_dupn_valid_utf8(o, out, _ctx);
  free(out);
  kk_bytes_drop(b, _ctx);
  return s;
}

static kk_string_t kk_bytesx_to_hex(kk_box_t bb, kk_context_t* _ctx) {
  static const char* digits = "0123456789abcdef";
  kk_bytes_t b = kk_bytes_unbox(bb);
  kk_ssize_t n = 0;
  const uint8_t* p = kk_bytes_buf_borrow(b, &n, _ctx);
  char* out = (char*)malloc((size_t)(n * 2 + 1));
  if (out == NULL) { kk_bytes_drop(b, _ctx); return kk_string_empty(); }
  for (kk_ssize_t i = 0; i < n; i++) {
    out[2*i]     = digits[(p[i] >> 4) & 0xF];
    out[2*i + 1] = digits[p[i] & 0xF];
  }
  out[n*2] = 0;
  kk_string_t s = kk_string_alloc_dupn_valid_utf8(n * 2, (const uint8_t*)out, _ctx);
  free(out);
  kk_bytes_drop(b, _ctx);
  return s;
}

static bool kk_bytesx_eq(kk_box_t ab, kk_box_t bb, kk_context_t* _ctx) {
  kk_bytes_t a = kk_bytes_unbox(ab);
  kk_bytes_t b = kk_bytes_unbox(bb);
  kk_ssize_t n = 0, m = 0;
  const uint8_t* p = kk_bytes_buf_borrow(a, &n, _ctx);
  const uint8_t* q = kk_bytes_buf_borrow(b, &m, _ctx);
  bool r = (n == m) && ((n == 0) || (memcmp(p, q, (size_t)n) == 0));
  kk_bytes_drop(a, _ctx);
  kk_bytes_drop(b, _ctx);
  return r;
}

static int32_t kk_bytesx_cmp(kk_box_t ab, kk_box_t bb, kk_context_t* _ctx) {
  kk_bytes_t a = kk_bytes_unbox(ab);
  kk_bytes_t b = kk_bytes_unbox(bb);
  kk_ssize_t n = 0, m = 0;
  const uint8_t* p = kk_bytes_buf_borrow(a, &n, _ctx);
  const uint8_t* q = kk_bytes_buf_borrow(b, &m, _ctx);
  kk_ssize_t k = (n < m ? n : m);
  int c = (k == 0 ? 0 : memcmp(p, q, (size_t)k));
  int32_t r = (c != 0 ? (c < 0 ? -1 : 1)
                      : (n == m ? 0 : (n < m ? -1 : 1)));
  kk_bytes_drop(a, _ctx);
  kk_bytes_drop(b, _ctx);
  return r;
}

/* FNV-1a, 64-bit, truncated to the platform word.  Not cryptographic. */
static kk_ssize_t kk_bytesx_hash(kk_box_t bb, kk_context_t* _ctx) {
  kk_bytes_t b = kk_bytes_unbox(bb);
  kk_ssize_t n = 0;
  const uint8_t* p = kk_bytes_buf_borrow(b, &n, _ctx);
  uint64_t h = 1469598103934665603ULL;
  for (kk_ssize_t i = 0; i < n; i++) {
    h ^= (uint64_t)p[i];
    h *= 1099511628211ULL;
  }
  kk_bytes_drop(b, _ctx);
  /* keep it non-negative so it can be used as a Koka `int` index */
  return (kk_ssize_t)(h & 0x3FFFFFFFFFFFFFFFULL);
}

/* ------------------------------------------------------------------ builder */

typedef struct kk_bbuf_s {
  uint8_t*  data;
  kk_ssize_t len;
  kk_ssize_t cap;
} kk_bbuf_t;

static void kk_bbuf_free(void* p, kk_block_t* block, kk_context_t* ctx) {
  kk_unused(block); kk_unused(ctx);
  kk_bbuf_t* b = (kk_bbuf_t*)p;
  if (b != NULL) {
    free(b->data);
    free(b);
  }
}

/* Grow to hold `extra` more octets.

   A builder that cannot grow must not quietly keep the octets it already has:
   this builder backs the JSON generator and the HTTP response writer, and a
   silently short response is a far worse failure than a loud one -- it is a
   corrupt message that every layer downstream will treat as valid.  kklib's
   own allocators abort on exhaustion for the same reason, so this matches the
   surrounding convention rather than inventing a new one.

   The failure is reported rather than returned because making it an exception
   would put `exn` in the row of every `snoc`, and so of every caller of the
   JSON generator and the response writer -- for a condition that, under
   mimalloc, the process does not survive anyway. */
static void kk_bbuf_fail(const char* what, kk_ssize_t want) {
  fprintf(stderr, "bytes/builder: cannot %s to %lld octets; out of memory\n",
          what, (long long)want);
  fflush(stderr);
  abort();
}

static bool kk_bbuf_ensure(kk_bbuf_t* b, kk_ssize_t extra) {
  if (b->len + extra <= b->cap) return true;
  kk_ssize_t cap = (b->cap < 32 ? 32 : b->cap);
  while (cap < b->len + extra) {
    if (cap > (kk_ssize_t)1 << 60) kk_bbuf_fail("grow", b->len + extra);
    cap *= 2;
  }
  uint8_t* nd = (uint8_t*)realloc(b->data, (size_t)cap);
  if (nd == NULL) kk_bbuf_fail("grow", cap);
  b->data = nd;
  b->cap  = cap;
  return true;
}

static kk_box_t kk_bytesx_builder_new(kk_ssize_t capacity, kk_context_t* _ctx) {
  kk_bbuf_t* b = (kk_bbuf_t*)calloc(1, sizeof(kk_bbuf_t));
  if (b != NULL && capacity > 0) {
    b->data = (uint8_t*)malloc((size_t)capacity);
    if (b->data != NULL) b->cap = capacity;
  }
  return kk_cptr_raw_box(&kk_bbuf_free, b, _ctx);
}

static kk_bbuf_t* kk_bbuf_of(kk_box_t bb, kk_context_t* ctx) {
  return (kk_bbuf_t*)kk_cptr_raw_unbox_borrowed(bb, ctx);
}

static kk_unit_t kk_bytesx_builder_reserve(kk_box_t bb, kk_ssize_t n, kk_context_t* _ctx) {
  kk_bbuf_t* b = kk_bbuf_of(bb, _ctx);
  if (b != NULL) kk_bbuf_ensure(b, n);
  kk_box_drop(bb, _ctx);
  return kk_Unit;
}

static kk_unit_t kk_bytesx_builder_push(kk_box_t bb, int32_t v, kk_context_t* _ctx) {
  kk_bbuf_t* b = kk_bbuf_of(bb, _ctx);
  if (b != NULL && kk_bbuf_ensure(b, 1)) {
    b->data[b->len++] = (uint8_t)(((uint32_t)v) & 0xFF);
  }
  kk_box_drop(bb, _ctx);
  return kk_Unit;
}

static kk_unit_t kk_bytesx_builder_append(kk_box_t bb, kk_box_t xb, kk_context_t* _ctx) {
  kk_bbuf_t* b = kk_bbuf_of(bb, _ctx);
  kk_bytes_t x = kk_bytes_unbox(xb);
  kk_ssize_t n = 0;
  const uint8_t* p = kk_bytes_buf_borrow(x, &n, _ctx);
  if (b != NULL && n > 0 && kk_bbuf_ensure(b, n)) {
    memcpy(b->data + b->len, p, (size_t)n);
    b->len += n;
  }
  kk_bytes_drop(x, _ctx);
  kk_box_drop(bb, _ctx);
  return kk_Unit;
}

static kk_unit_t kk_bytesx_builder_append_string(kk_box_t bb, kk_string_t s, kk_context_t* _ctx) {
  kk_bbuf_t* b = kk_bbuf_of(bb, _ctx);
  kk_ssize_t n = 0;
  const uint8_t* p = (const uint8_t*)kk_string_cbuf_borrow(s, &n, _ctx);
  if (b != NULL && n > 0 && kk_bbuf_ensure(b, n)) {
    memcpy(b->data + b->len, p, (size_t)n);
    b->len += n;
  }
  kk_string_drop(s, _ctx);
  kk_box_drop(bb, _ctx);
  return kk_Unit;
}

static kk_ssize_t kk_bytesx_builder_length(kk_box_t bb, kk_context_t* _ctx) {
  kk_bbuf_t* b = kk_bbuf_of(bb, _ctx);
  kk_ssize_t n = (b == NULL ? 0 : b->len);
  kk_box_drop(bb, _ctx);
  return n;
}

/* Hand over the accumulated octets and reset the buffer so the builder can be
   reused.  The buffer memory itself stays with the builder and is released
   when the builder value is dropped. */
static kk_box_t kk_bytesx_builder_finish(kk_box_t bb, kk_context_t* _ctx) {
  kk_bbuf_t* b = kk_bbuf_of(bb, _ctx);
  if (b == NULL || b->len == 0) { kk_box_drop(bb, _ctx); return kk_bytes_box(kk_bytes_empty()); }
  kk_bytes_t out = kk_bytes_alloc_dupn(b->len, b->data, _ctx);
  b->len = 0;
  kk_box_drop(bb, _ctx);
  return kk_bytes_box(out);
}
