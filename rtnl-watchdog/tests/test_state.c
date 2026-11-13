/* SPDX-License-Identifier: GPL-2.0 */
#include "watchdog.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>
static const char *boot = "01234567-89ab-cdef-0123-456789abcdef";
int main(void)
{
  struct wd_config c; wd_config_defaults(&c); struct wd_model m;
  assert(!strcmp(c.state_file, "/run/rtnl-watchdog.json"));
  assert(!strcmp(c.lock_file, "/run/rtnl-watchdog.lock"));
  assert(!strcmp(c.metrics_file, "/run/metrics/rtnl-watchdog.prom"));
  assert(!wd_model_init(&m, boot, "observer-helper-1"));
  assert(wd_model_init(&m, "bad", "epoch") < 0);
  assert(!wd_model_init(&m, boot, "observer-helper-1"));
  assert(!wd_dispatch(&m, 1000000000ULL));
  assert(wd_dispatch(&m, 1000000001ULL) < 0 && m.probe_sequence == 1);
  wd_observe(&m, 9000000000ULL, 9.0, &c);
  assert(m.state == WD_PENDING && !m.started_ns); /* Dispatch age alone is unknown. */
  struct wd_message start = { .type = WD_STARTED, .sequence = 1, .started_ns = 9000000000ULL };
  assert(!wd_apply(&m, &start, 9000000000ULL, 9.0));
  wd_observe(&m, 9999999999ULL, 10.0, &c); assert(m.state == WD_PENDING);
  wd_observe(&m, 10000000000ULL, 10.0, &c); assert(m.state == WD_DISTRESSED && !m.last_success_realtime);
  for (unsigned i = 0; i < 4; i++) {
    wd_observe(&m, 11000000000ULL + i, 11.0, &c);
    assert(m.state == WD_DISTRESSED && m.probe_sequence == 1 && wd_dispatch(&m, 11000000000ULL + i) < 0);
  }
  struct wd_message done = { .type = WD_COMPLETED, .sequence = 1, .started_ns = start.started_ns, .completed_ns = 12000000000ULL };
  assert(wd_apply(&m, &done, done.completed_ns, 12.0) == 1);
  wd_completion_metrics(&m, &c); wd_completion_metrics(&m, &c);
  assert(m.history.responses == 1 && m.history.overdue == 1 && m.history.buckets[7] == 1 && m.history.buckets[4] == 0);
  assert(m.state == WD_HEALTHY && !m.inflight && m.last_duration_ns == 3000000000ULL && m.last_success_realtime == 12.0);
  wd_observe(&m, 12000000001ULL, 12.0, &c);
  char json[WD_JSON_LIMIT + 1], metrics[WD_JSON_LIMIT + 1];
  assert(wd_json(&m, json, sizeof(json)) > 0 && strstr(json, "\"state\":\"healthy\""));
  assert(strstr(json, "\"expected_errno\":22") && strstr(json, "\"last_duration_ns\":3000000000"));
  assert(wd_metrics(&m, 0, 0, metrics, sizeof(metrics)) > 0 && strstr(metrics, "rtnl_watchdog_distress 0\n"));
  assert(!wd_dispatch(&m, 13000000000ULL) && m.last_duration_ns == 3000000000ULL);
  wd_observe(&m, 15000000000ULL, 15.0, &c);
  assert(wd_json(&m, json, sizeof(json)) > 0 && strstr(json, "\"started_monotonic_ns\":null"));
  assert(strstr(json, "\"last_duration_ns\":3000000000"));
  assert(wd_metrics(&m, 2, 3, metrics, sizeof(metrics)) > 0 && !strstr(metrics, "\nrtnl_watchdog_distress "));
  assert(strstr(metrics, "# TYPE rtnl_watchdog_distress gauge\n"));
  assert(strstr(metrics, "rtnl_watchdog_output_errors_total 5") && strstr(metrics, "rtnl_watchdog_response_duration_seconds_count 1"));
  assert(!strstr(metrics, "osctl_rtnl_watchdog_"));
  struct wd_message wrong = { .type = WD_STARTED, .sequence = 99, .started_ns = 13000000000ULL };
  assert(wd_apply(&m, &wrong, 15000000000ULL, 15.0) < 0 && m.inflight && m.state == WD_ERROR);
  assert(wd_dispatch(&m, 16000000000ULL) < 0); /* Unknown effects do not free the slot. */
  assert(!wd_model_init(&m, boot, "new-epoch") && !m.inflight && !m.sequence && !m.last_duration_ns);
  assert(!wd_dispatch(&m, 100));
  done = (struct wd_message){ .type = WD_COMPLETED, .sequence = 1, .completed_ns = 200, .error = WD_NAMESPACE };
  assert(wd_apply(&m, &done, 200, 1.0) == 1 && m.state == WD_ERROR && !m.inflight && m.error == WD_NAMESPACE);
  wd_completion_metrics(&m, &c); assert(!m.history.overdue && !m.history.responses);
  assert(!wd_dispatch(&m, 300)); start = (struct wd_message){ .type = WD_STARTED, .sequence = 2, .started_ns = 299 };
  assert(wd_apply(&m, &start, 400, 1.0) < 0 && m.state == WD_ERROR && m.inflight);
  assert(!wd_model_init(&m, boot, "fresh") && !wd_dispatch(&m, 100));
  start = (struct wd_message){ .type = WD_STARTED, .sequence = 1, .started_ns = 200 };
  assert(wd_apply(&m, &start, 199, 1.0) < 0); /* Future ACK is not evidence. */
  /* A completed slow response between ticks is retained without a prior alarm. */
  assert(!wd_model_init(&m, boot, "metrics") && !wd_dispatch(&m, 1000000000ULL));
  start = (struct wd_message){ .type = WD_STARTED, .sequence = 1, .started_ns = 1000000000ULL };
  assert(!wd_apply(&m, &start, start.started_ns, 1.0));
  done = (struct wd_message){ .type = WD_COMPLETED, .sequence = 1, .started_ns = start.started_ns, .completed_ns = 2500000000ULL };
  assert(wd_apply(&m, &done, done.completed_ns, 2.5) == 1); wd_completion_metrics(&m, &c);
  assert(m.history.overdue == 1 && m.history.responses == 1 && m.history.response_sum_ns == 1500000000ULL);
  assert(!wd_dispatch(&m, 3000000000ULL)); start.sequence = 2; start.started_ns = 3000000000ULL;
  assert(!wd_apply(&m, &start, start.started_ns, 3.0));
  done = (struct wd_message){ .type = WD_COMPLETED, .sequence = 2, .started_ns = start.started_ns, .completed_ns = 4500000000ULL, .error = WD_REPLY };
  assert(wd_apply(&m, &done, done.completed_ns, 4.5) == 1); wd_completion_metrics(&m, &c);
  assert(m.history.overdue == 2 && m.history.responses == 1); /* Timed error, not a valid response. */
  assert(!wd_model_rebind(&m, boot, "metrics-new-helper") && m.history.overdue == 2 && m.history.responses == 1 && !m.has_duration && !m.probe_sequence);
  assert(wd_metrics(&m, 0, 0, metrics, sizeof(metrics)) > 0 && !strstr(metrics, "\nrtnl_watchdog_last_probe_duration_seconds "));
  assert(strstr(metrics, "rtnl_watchdog_response_duration_seconds_bucket{le=\"+Inf\"} 1"));
  /* Each fixed boundary is inclusive; cumulative buckets contain all lower observations. */
  const uint64_t boundaries[] = { 1000000ULL, 10000000ULL, 100000000ULL,
    500000000ULL, 1000000000ULL, 5000000000ULL, 10000000000ULL };
  assert(!wd_model_init(&m, boot, "bucket-boundaries"));
  uint64_t now = 1000000000ULL, sum = 0;
  for (unsigned i = 0; i < sizeof(boundaries)/sizeof(*boundaries); i++) {
    assert(!wd_dispatch(&m, now));
    start = (struct wd_message){ .type = WD_STARTED, .sequence = m.probe_sequence, .started_ns = now };
    assert(!wd_apply(&m, &start, now, 1.0));
    done = (struct wd_message){ .type = WD_COMPLETED, .sequence = m.probe_sequence,
      .started_ns = now, .completed_ns = now + boundaries[i] };
    assert(wd_apply(&m, &done, done.completed_ns, 20.0) == 1);
    wd_completion_metrics(&m, &c); wd_completion_metrics(&m, &c);
    sum += boundaries[i];
    assert(m.history.responses == i + 1 && m.history.response_sum_ns == sum);
    for (unsigned j = 0; j < WD_BUCKETS; j++)
      assert(m.history.buckets[j] == (j < i ? j + 1 : i + 1));
    now = done.completed_ns + 1;
  }
  char *valid[] = { "watchdog", "--threshold-ms", "100", "--tick-ms", "50" };
  wd_config_defaults(&c); assert(!wd_config_parse(&c, 5, valid));
  const char *bad[] = {"-1", "0", "nan", "60001", "9999999999999999999999"};
  for (unsigned i = 0; i < sizeof(bad)/sizeof(*bad); i++) {
    char *args[] = { "watchdog", "--threshold-ms", (char *)bad[i] };
    wd_config_defaults(&c); assert(wd_config_parse(&c, 3, args) < 0);
  }
  char *alias[] = { "watchdog", "--state-file", "/run/./rtnl-watchdog.lock" };
  wd_config_defaults(&c); assert(wd_config_parse(&c, 3, alias) < 0);
  puts("watchdog single-flight/timing/error/schema units passed; no probe"); return 0;
}
