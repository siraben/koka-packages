/* C support for kktest/sys.
   POSIX only; this development program does not target Windows.
*/
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <signal.h>
#include <dirent.h>
#include <sys/stat.h>
#include <sys/types.h>

/* `exit`, not `_exit`: atexit handlers must run, because that is where
   LeakSanitizer performs its check.  A test run that skipped it would report
   "no leaks" without having looked. */
static kk_unit_t kk_test_exit(int32_t code, kk_context_t* _ctx) {
  kk_unused(_ctx);
  fflush(stdout);
  fflush(stderr);
  exit((int)code);
  return kk_Unit;
}

static int64_t kk_test_mono_ms(kk_context_t* _ctx) {
  kk_unused(_ctx);
  struct timespec ts;
  if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) return 0;
  return (int64_t)ts.tv_sec * 1000 + (int64_t)(ts.tv_nsec / 1000000);
}

/* The watchdog message is copied into a static buffer because the SIGALRM
   handler may only use async-signal-safe calls: it write(2)s the buffer and
   _exit(2)s.  It must not touch the Koka heap. */
#define KK_TEST_WD_MAX 256
static char kk_test_wd_msg[KK_TEST_WD_MAX];

static void kk_test_wd_handler(int sig) {
  (void)sig;
  ssize_t r = write(2, kk_test_wd_msg, strlen(kk_test_wd_msg));
  (void)r;
  _exit(124);   /* the conventional "timed out" status */
}

static kk_unit_t kk_test_set_watchdog(int32_t seconds, kk_string_t msg, kk_context_t* _ctx) {
  if (seconds <= 0) {
    alarm(0);
    kk_string_drop(msg, _ctx);
    return kk_Unit;
  }
  kk_ssize_t len = 0;
  const char* s = kk_string_cbuf_borrow(msg, &len, _ctx);
  size_t n = (size_t)len;
  if (n > KK_TEST_WD_MAX - 2) n = KK_TEST_WD_MAX - 2;
  memcpy(kk_test_wd_msg, s, n);
  kk_test_wd_msg[n] = '\n';
  kk_test_wd_msg[n + 1] = 0;
  kk_string_drop(msg, _ctx);

  struct sigaction sa;
  memset(&sa, 0, sizeof(sa));
  sa.sa_handler = &kk_test_wd_handler;
  sigemptyset(&sa.sa_mask);
  sigaction(SIGALRM, &sa, NULL);
  alarm((unsigned int)seconds);
  return kk_Unit;
}

static kk_string_t kk_test_make_temp_dir(kk_string_t prefix, kk_context_t* _ctx) {
  kk_ssize_t plen = 0;
  const char* p = kk_string_cbuf_borrow(prefix, &plen, _ctx);
  const char* tmp = getenv("TMPDIR");
  if (tmp == NULL || tmp[0] == 0) tmp = "/tmp";

  char templ[1024];
  int n = snprintf(templ, sizeof(templ), "%s/%.*s-XXXXXX", tmp, (int)plen, p);
  kk_string_drop(prefix, _ctx);
  if (n <= 0 || (size_t)n >= sizeof(templ)) return kk_string_empty();

  if (mkdtemp(templ) == NULL) return kk_string_empty();
  return kk_string_alloc_from_utf8(templ, _ctx);
}

static int kk_test_remove_tree_c(const char* path) {
  struct stat st;
  if (lstat(path, &st) != 0) return 0;          /* nothing there: fine */
  if (!S_ISDIR(st.st_mode)) return unlink(path);

  DIR* d = opendir(path);
  if (d == NULL) return -1;
  struct dirent* e;
  char child[4096];
  while ((e = readdir(d)) != NULL) {
    if (strcmp(e->d_name, ".") == 0 || strcmp(e->d_name, "..") == 0) continue;
    int n = snprintf(child, sizeof(child), "%s/%s", path, e->d_name);
    if (n > 0 && (size_t)n < sizeof(child)) kk_test_remove_tree_c(child);
  }
  closedir(d);
  return rmdir(path);
}

static kk_unit_t kk_test_remove_tree(kk_string_t path, kk_context_t* _ctx) {
  kk_ssize_t len = 0;
  const char* p = kk_string_cbuf_borrow(path, &len, _ctx);
  char buf[4096];
  int n = snprintf(buf, sizeof(buf), "%.*s", (int)len, p);
  kk_string_drop(path, _ctx);
  if (n > 0 && (size_t)n < sizeof(buf)) kk_test_remove_tree_c(buf);
  return kk_Unit;
}

static bool kk_test_path_exists(kk_string_t path, kk_context_t* _ctx) {
  kk_ssize_t len = 0;
  const char* p = kk_string_cbuf_borrow(path, &len, _ctx);
  char buf[4096];
  int n = snprintf(buf, sizeof(buf), "%.*s", (int)len, p);
  kk_string_drop(path, _ctx);
  if (n <= 0 || (size_t)n >= sizeof(buf)) return false;
  struct stat st;
  return (stat(buf, &st) == 0);
}
