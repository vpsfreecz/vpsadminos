/* SPDX-License-Identifier: GPL-2.0 */
#include "watchdog.h"
#include <ctype.h>
#include <errno.h>
#include <inttypes.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <stdlib.h>
uint64_t wd_now(void)
{
  struct timespec t; if (clock_gettime(CLOCK_MONOTONIC, &t)) abort();
  return (uint64_t)t.tv_sec * 1000000000ULL + t.tv_nsec;
}
double wd_realtime(void)
{
  struct timespec t; if (clock_gettime(CLOCK_REALTIME, &t)) abort();
  return t.tv_sec + t.tv_nsec / 1e9;
}
const char *wd_state_name(enum wd_state state)
{
  static const char *names[] = { "starting", "pending", "distressed", "healthy", "error" };
  return state >= WD_STARTING && state <= WD_ERROR ? names[state] : "error";
}
const char *wd_error_name(unsigned error)
{
  static const char *names[] = { "none", "namespace", "socket", "send", "receive", "reply", "ipc", "child" };
  return error < WD_ERROR_COUNT ? names[error] : "ipc";
}
int wd_model_init(struct wd_model *m, const char *boot, const char *epoch)
{
  if (strlen(boot) != 36 || !*epoch || strlen(epoch) >= sizeof(m->epoch)) return -1;
  for (unsigned i = 0; i < 36; i++) {
    bool dash = i == 8 || i == 13 || i == 18 || i == 23;
    if (dash ? boot[i] != '-' : !isxdigit((unsigned char)boot[i])) return -1;
  }
  for (const char *s = epoch; *s; s++) if (!isalnum((unsigned char)*s) && *s != '-' && *s != '_') return -1;
  memset(m, 0, sizeof(*m)); strcpy(m->boot_id, boot); strcpy(m->epoch, epoch); return 0;
}
int wd_model_rebind(struct wd_model *m, const char *boot, const char *epoch)
{
  struct wd_history history = m->history; uint64_t errors[WD_ERROR_COUNT];
  memcpy(errors, m->errors, sizeof(errors));
  int result = wd_model_init(m, boot, epoch);
  m->history = history; memcpy(m->errors, errors, sizeof(errors)); return result;
}
void wd_fail(struct wd_model *m, unsigned error)
{
  if (!error || error >= WD_ERROR_COUNT) error = WD_IPC;
  m->error = error; m->errors[error]++; m->state = WD_ERROR;
}
int wd_dispatch(struct wd_model *m, uint64_t now)
{
  if (m->inflight || !now) return -1;
  m->inflight = true; m->probe_sequence++; m->dispatch_ns = now;
  m->started_ns = m->completed_ns = 0; m->state = WD_PENDING; m->error = WD_OK;
  m->overdue_counted = m->completion_counted = false;
  return 0;
}
int wd_apply(struct wd_model *m, const struct wd_message *v, uint64_t now, double realtime)
{
  if (!m->inflight || m->state == WD_ERROR || v->sequence != m->probe_sequence || v->error >= WD_ERROR_COUNT) goto invalid;
  if (v->type == WD_STARTED) {
    if (m->started_ns || v->error || v->completed_ns || v->started_ns < m->dispatch_ns || v->started_ns > now) goto invalid;
    m->started_ns = v->started_ns; return 0;
  }
  if (v->type != WD_COMPLETED || v->completed_ns < m->dispatch_ns || v->completed_ns > now) goto invalid;
  if (v->started_ns != m->started_ns || (!m->started_ns && v->error != WD_NAMESPACE && v->error != WD_SOCKET)) goto invalid;
  if (m->started_ns && v->completed_ns < m->started_ns) goto invalid;
  m->inflight = false; m->completed_ns = v->completed_ns;
  if (v->error) wd_fail(m, v->error);
  else {
    m->last_duration_ns = v->completed_ns - m->started_ns; m->has_duration = true;
    m->state = WD_HEALTHY; m->error = WD_OK;
    m->last_success_realtime = realtime - (now - v->completed_ns) / 1e9;
  }
  return 1;
invalid:
  wd_fail(m, WD_IPC); return -1; /* Keep the uncertain request reserved. */
}
static void overdue(struct wd_model *m, uint64_t age, const struct wd_config *c)
{
  if (!m->overdue_counted && age >= (uint64_t)c->threshold_ms * WD_NS_PER_MS) {
    m->history.overdue++; m->overdue_counted = true;
  }
}
void wd_completion_metrics(struct wd_model *m, const struct wd_config *c)
{
  static const uint64_t bounds[WD_BUCKETS] = { 1000000ULL, 10000000ULL, 100000000ULL, 500000000ULL,
    1000000000ULL, 5000000000ULL, 10000000000ULL, UINT64_MAX };
  if (m->completion_counted || m->inflight || !m->completed_ns) return;
  m->completion_counted = true;
  if (!m->started_ns || m->completed_ns < m->started_ns) return;
  uint64_t duration = m->completed_ns - m->started_ns;
  overdue(m, duration, c); /* Includes timed errors, even between observer ticks. */
  if (m->state != WD_HEALTHY || m->error) return;
  m->history.responses++; m->history.response_sum_ns += duration;
  for (unsigned i = 0; i < WD_BUCKETS; i++) if (duration <= bounds[i]) m->history.buckets[i]++;
}
void wd_observe(struct wd_model *m, uint64_t now, double realtime, const struct wd_config *c)
{
  m->observed_ns = now; m->observed_realtime = realtime; m->sequence++;
  if (m->inflight && m->state != WD_ERROR) {
    if (m->started_ns && now >= m->started_ns) overdue(m, now - m->started_ns, c);
    m->state = m->started_ns && now >= m->started_ns &&
      now - m->started_ns >= (uint64_t)c->threshold_ms * WD_NS_PER_MS ? WD_DISTRESSED : WD_PENDING;
  }
}
static const char *number(char *text, uint64_t value)
{
  if (!value) return "null";
  snprintf(text, 32, "%" PRIu64, value); return text;
}
int wd_json(const struct wd_model *m, char *buffer, size_t size)
{
  char dispatch[32], start[32], end[32], duration[32];
  const char *duration_text = "null";
  if (m->has_duration) { snprintf(duration, sizeof(duration), "%" PRIu64, m->last_duration_ns); duration_text = duration; }
  int n = snprintf(buffer, size,
    "{\"schema\":1,\"boot_id\":\"%s\",\"epoch\":\"%s\",\"sequence\":%" PRIu64 ",\"observed_monotonic_ns\":%" PRIu64
    ",\"probe_sequence\":%" PRIu64 ",\"state\":\"%s\",\"dispatch_monotonic_ns\":%s,\"started_monotonic_ns\":%s"
    ",\"completed_monotonic_ns\":%s,\"last_duration_ns\":%s,\"expected_errno\":%d,\"error_code\":%u}\n",
    m->boot_id, m->epoch, m->sequence, m->observed_ns, m->probe_sequence, wd_state_name(m->state),
    number(dispatch, m->dispatch_ns), number(start, m->started_ns), number(end, m->completed_ns),
    duration_text, EINVAL, m->error);
  return n < 0 || (size_t)n >= size || n > WD_JSON_LIMIT ? -1 : n;
}
int wd_metrics(const struct wd_model *m, uint64_t drops, uint64_t failures, char *buffer, size_t size)
{
  bool available = m->state == WD_HEALTHY || (m->inflight && m->started_ns && m->state != WD_ERROR);
  int n = snprintf(buffer, size,
    "# TYPE rtnl_watchdog_available gauge\n# TYPE rtnl_watchdog_distress gauge\n"
    "# TYPE rtnl_watchdog_pending_age_seconds gauge\n# TYPE rtnl_watchdog_last_probe_duration_seconds gauge\n"
    "# TYPE rtnl_watchdog_last_success_timestamp_seconds gauge\n# TYPE rtnl_watchdog_snapshot_timestamp_seconds gauge\n"
    "# TYPE rtnl_watchdog_errors_total counter\n# TYPE rtnl_watchdog_output_errors_total counter\n"
    "# TYPE rtnl_watchdog_overdue_probes_total counter\n"
    "rtnl_watchdog_available %u\nrtnl_watchdog_snapshot_timestamp_seconds %.9f\n"
    "rtnl_watchdog_output_errors_total %" PRIu64 "\n",
    available, m->observed_realtime, drops + failures);
  if (n < 0 || (size_t)n >= size) return -1;
#define APPEND(...) do { int k = snprintf(buffer + n, size - n, __VA_ARGS__); if (k < 0 || (size_t)k >= size - n) return -1; n += k; } while (0)
  if (available) APPEND("rtnl_watchdog_distress %u\n", m->state == WD_DISTRESSED);
  if (!m->inflight || m->started_ns) APPEND("rtnl_watchdog_pending_age_seconds %.9f\n",
    m->inflight && m->observed_ns >= m->started_ns ? (m->observed_ns - m->started_ns) / 1e9 : 0.0);
  if (m->has_duration) APPEND("rtnl_watchdog_last_probe_duration_seconds %.9f\n", m->last_duration_ns / 1e9);
  if (m->last_success_realtime) APPEND("rtnl_watchdog_last_success_timestamp_seconds %.9f\n", m->last_success_realtime);
  uint64_t errors = 0; for (unsigned i = 1; i < WD_ERROR_COUNT; i++) errors += m->errors[i];
  APPEND("rtnl_watchdog_errors_total %" PRIu64 "\n", errors);
  APPEND("rtnl_watchdog_overdue_probes_total %" PRIu64 "\n", m->history.overdue);
  APPEND("# TYPE rtnl_watchdog_response_duration_seconds histogram\n");
  static const char *labels[] = { "0.001", "0.01", "0.1", "0.5", "1", "5", "10", "+Inf" };
  for (unsigned i = 0; i < WD_BUCKETS; i++) APPEND("rtnl_watchdog_response_duration_seconds_bucket{le=\"%s\"} %" PRIu64 "\n", labels[i], m->history.buckets[i]);
  APPEND("rtnl_watchdog_response_duration_seconds_sum %.9f\n", m->history.response_sum_ns / 1e9);
  APPEND("rtnl_watchdog_response_duration_seconds_count %" PRIu64 "\n", m->history.responses);
#undef APPEND
  return n;
}
