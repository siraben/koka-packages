/* C support for `fileio/file`.  POSIX only.

   Every function reports failure through a negative errno rather than by
   throwing, so the Koka side decides what an error means and can classify it.
*/
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/stat.h>
#include <sys/types.h>

/* open flags, kept as small integers so the Koka side does not depend on the
   platform's O_* values */
#define KKF_READ    1
#define KKF_WRITE   2
#define KKF_CREATE  4
#define KKF_TRUNC   8
#define KKF_APPEND 16
#define KKF_EXCL   32

static kk_string_t kk_fio_borrow_path(kk_string_t path, char* buf, size_t buflen, kk_context_t* _ctx) {
  kk_ssize_t len = 0;
  const char* p = kk_string_cbuf_borrow(path, &len, _ctx);
  size_t n = (size_t)len;
  if (n >= buflen) n = buflen - 1;
  memcpy(buf, p, n);
  buf[n] = 0;
  return path;
}

/* Returns a file descriptor, or -errno. */
static int32_t kk_fio_open(kk_string_t path, int32_t flags, int32_t mode, kk_context_t* _ctx) {
  char buf[4096];
  kk_fio_borrow_path(path, buf, sizeof(buf), _ctx);
  kk_string_drop(path, _ctx);

  int f = 0;
  const int32_t rw = flags & (KKF_READ | KKF_WRITE);
  if (rw == (KKF_READ | KKF_WRITE)) f = O_RDWR;
  else if (rw == KKF_WRITE)          f = O_WRONLY;
  else                               f = O_RDONLY;
  if (flags & KKF_CREATE) f |= O_CREAT;
  if (flags & KKF_TRUNC)  f |= O_TRUNC;
  if (flags & KKF_APPEND) f |= O_APPEND;
  if (flags & KKF_EXCL)   f |= O_EXCL;
#ifdef O_CLOEXEC
  f |= O_CLOEXEC;   /* a forked child must not inherit our descriptors */
#endif

  int fd;
  do { fd = open(buf, f, (mode_t)mode); } while (fd < 0 && errno == EINTR);
  return (fd < 0 ? -(int32_t)errno : (int32_t)fd);
}

/* 0 on success, -errno on failure.  Closing an already-closed descriptor is
   the caller's bug, but we still report it rather than aborting. */
static int32_t kk_fio_close(int32_t fd, kk_context_t* _ctx) {
  kk_unused(_ctx);
  int r;
  do { r = close((int)fd); } while (r < 0 && errno == EINTR);
  return (r < 0 ? -(int32_t)errno : 0);
}

/* Why the most recent kk_fio_read returned nothing: 0 when it did not fail,
   and the errno otherwise.  It is *not* the process-wide `errno`: that is left
   untouched by a successful read and by a read that reaches end of file, so
   reading it back after the fact reports whatever the last failing syscall
   anywhere in the process happened to leave behind.  This is written on every
   call, so it always describes that call and nothing else.

   Single threaded by construction: the file API is not shared across threads
   in this program. */
static int32_t kk_fio_read_errno = 0;

/* Read at most `max` octets.  Returns the octets read; an empty result means
   end of file when kk_fio_read_error is 0, and a failure otherwise.  A short
   read is not an error: it is what a pipe, a socket or a signal gives you. */
static kk_box_t kk_fio_read(int32_t fd, kk_ssize_t max, kk_context_t* _ctx) {
  kk_fio_read_errno = 0;
  if (max <= 0) return kk_bytes_box(kk_bytes_empty());
  uint8_t* tmp = (uint8_t*)malloc((size_t)max);
  if (tmp == NULL) { kk_fio_read_errno = ENOMEM; return kk_bytes_box(kk_bytes_empty()); }
  ssize_t n;
  do { n = read((int)fd, tmp, (size_t)max); } while (n < 0 && errno == EINTR);
  if (n < 0) kk_fio_read_errno = (int32_t)errno;
  kk_bytes_t out = (n <= 0) ? kk_bytes_empty()
                            : kk_bytes_alloc_dupn((kk_ssize_t)n, tmp, _ctx);
  free(tmp);
  return kk_bytes_box(out);
}

/* Why the last read returned nothing, so the Koka side can tell "end of file"
   from "error".  Asked for only when the read came back empty. */
static int32_t kk_fio_read_error(kk_context_t* _ctx) {
  kk_unused(_ctx);
  return kk_fio_read_errno;
}

/* Write everything, looping over short writes.  Returns octets written or
   -errno. */
static kk_ssize_t kk_fio_write_all(int32_t fd, kk_box_t datab, kk_context_t* _ctx) {
  kk_bytes_t data = kk_bytes_unbox(datab);
  kk_ssize_t len = 0;
  const uint8_t* p = kk_bytes_buf_borrow(data, &len, _ctx);
  kk_ssize_t off = 0;
  kk_ssize_t r = 0;
  while (off < len) {
    ssize_t n;
    do { n = write((int)fd, p + off, (size_t)(len - off)); } while (n < 0 && errno == EINTR);
    if (n < 0) { r = -(kk_ssize_t)errno; goto done; }
    off += (kk_ssize_t)n;
  }
  r = off;
done:
  kk_bytes_drop(data, _ctx);
  return r;
}

static int32_t kk_fio_fsync(int32_t fd, kk_context_t* _ctx) {
  kk_unused(_ctx);
  int r;
  do { r = fsync((int)fd); } while (r < 0 && errno == EINTR);
  return (r < 0 ? -(int32_t)errno : 0);
}

/* Seek; returns the new offset or -errno.  whence: 0=set 1=cur 2=end. */
static int64_t kk_fio_seek(int32_t fd, int64_t off, int32_t whence, kk_context_t* _ctx) {
  kk_unused(_ctx);
  int w = (whence == 1 ? SEEK_CUR : (whence == 2 ? SEEK_END : SEEK_SET));
  off_t r = lseek((int)fd, (off_t)off, w);
  return (r < 0 ? -(int64_t)errno : (int64_t)r);
}

/* Why the most recent kk_fio_kind or kk_fio_mtime gave up: 0 when the stat
   succeeded and the errno otherwise.  Neither of those two can report failure
   in its return value -- every small integer is a legitimate kind, and every
   int64 (negative ones included: st_mtime is signed, and a file older than
   1970 has a negative one) is a legitimate modification time -- so the reason
   lives here and the Koka side asks for it only when the answer is ambiguous.
   Written on every call, like kk_fio_read_errno. */
static int32_t kk_fio_stat_errno = 0;

static int32_t kk_fio_stat_error(kk_context_t* _ctx) {
  kk_unused(_ctx);
  return kk_fio_stat_errno;
}

/* Metadata.  Returns size, or -errno; a size is never negative, so that one
   can carry its own failure.  `kind` and `mtime` come from the companion calls
   so the Koka side can keep a simple record. */
static int64_t kk_fio_size(kk_string_t path, kk_context_t* _ctx) {
  char buf[4096];
  kk_fio_borrow_path(path, buf, sizeof(buf), _ctx);
  kk_string_drop(path, _ctx);
  struct stat st;
  if (stat(buf, &st) != 0) return -(int64_t)errno;
  return (int64_t)st.st_size;
}

/* 0 = the stat failed (kk_fio_stat_error says why -- "missing" is only one of
   the reasons), 1 = regular file, 2 = directory, 3 = other */
static int32_t kk_fio_kind(kk_string_t path, kk_context_t* _ctx) {
  char buf[4096];
  kk_fio_borrow_path(path, buf, sizeof(buf), _ctx);
  kk_string_drop(path, _ctx);
  struct stat st;
  kk_fio_stat_errno = 0;
  if (stat(buf, &st) != 0) { kk_fio_stat_errno = (int32_t)errno; return 0; }
  if (S_ISREG(st.st_mode)) return 1;
  if (S_ISDIR(st.st_mode)) return 2;
  return 3;
}

/* The modification time, which is signed and negative for a file older than
   1970, so failure is reported as 0 plus kk_fio_stat_error rather than by the
   sign.  0 is also a legitimate time (the epoch itself); that is the one value
   the Koka side has to ask about. */
static int64_t kk_fio_mtime(kk_string_t path, kk_context_t* _ctx) {
  char buf[4096];
  kk_fio_borrow_path(path, buf, sizeof(buf), _ctx);
  kk_string_drop(path, _ctx);
  struct stat st;
  kk_fio_stat_errno = 0;
  if (stat(buf, &st) != 0) { kk_fio_stat_errno = (int32_t)errno; return 0; }
  return (int64_t)st.st_mtime;
}

static int32_t kk_fio_rename(kk_string_t from, kk_string_t to, kk_context_t* _ctx) {
  char fbuf[4096], tbuf[4096];
  kk_fio_borrow_path(from, fbuf, sizeof(fbuf), _ctx);
  kk_fio_borrow_path(to, tbuf, sizeof(tbuf), _ctx);
  kk_string_drop(from, _ctx);
  kk_string_drop(to, _ctx);
  return (rename(fbuf, tbuf) != 0 ? -(int32_t)errno : 0);
}

static int32_t kk_fio_unlink(kk_string_t path, kk_context_t* _ctx) {
  char buf[4096];
  kk_fio_borrow_path(path, buf, sizeof(buf), _ctx);
  kk_string_drop(path, _ctx);
  return (unlink(buf) != 0 ? -(int32_t)errno : 0);
}

/* Create and open a unique temporary file next to `templ` (which must end in
   XXXXXX).  Returns the descriptor or -errno; the chosen name is read back
   with kk_fio_temp_name. */
static char kk_fio_temp_path[4096];

static int32_t kk_fio_mkstemp(kk_string_t templ, kk_context_t* _ctx) {
  kk_fio_borrow_path(templ, kk_fio_temp_path, sizeof(kk_fio_temp_path), _ctx);
  kk_string_drop(templ, _ctx);
  int fd = mkstemp(kk_fio_temp_path);
  return (fd < 0 ? -(int32_t)errno : (int32_t)fd);
}

static kk_string_t kk_fio_temp_name(kk_context_t* _ctx) {
  return kk_string_alloc_from_utf8(kk_fio_temp_path, _ctx);
}

/* A human readable message for an errno, so error text is useful. */
static kk_string_t kk_fio_strerror(int32_t err, kk_context_t* _ctx) {
  const char* s = strerror((int)(err < 0 ? -err : err));
  return kk_string_alloc_from_utf8(s == NULL ? "unknown error" : s, _ctx);
}

/* Directory of a path, for creating a temporary file on the same filesystem
   (rename is only atomic within one filesystem). */
static kk_string_t kk_fio_dirname(kk_string_t path, kk_context_t* _ctx) {
  char buf[4096];
  kk_fio_borrow_path(path, buf, sizeof(buf), _ctx);
  kk_string_drop(path, _ctx);
  char* slash = strrchr(buf, '/');
  if (slash == NULL) return kk_string_alloc_from_utf8(".", _ctx);
  if (slash == buf) return kk_string_alloc_from_utf8("/", _ctx);
  *slash = 0;
  return kk_string_alloc_from_utf8(buf, _ctx);
}
