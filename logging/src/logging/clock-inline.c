/* Wall-clock milliseconds for log timestamps. */
#include <time.h>

static kk_integer_t kk_log_now_ms(kk_context_t* _ctx) {
  struct timespec ts;
  if (clock_gettime(CLOCK_REALTIME, &ts) != 0) return kk_integer_from_int(0, _ctx);
  int64_t ms = (int64_t)ts.tv_sec * 1000 + (int64_t)(ts.tv_nsec / 1000000);
  return kk_integer_from_int64(ms, _ctx);
}
