/* SPDX-License-Identifier: GPL-2.0 */
#include "watchdog.h"
#include <errno.h>
#include <getopt.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>
static bool clean_path(const char *path)
{
  size_t n = strlen(path);
  if (path[0] != '/' || n < 2 || n >= PATH_MAX || path[n-1] == '/') return false;
  const char *part = path + 1;
  while (*part) {
    const char *end = strchr(part, '/'); size_t len = end ? (size_t)(end-part) : strlen(part);
    if (!len || (len == 1 && part[0] == '.') || (len == 2 && part[0] == '.' && part[1] == '.')) return false;
    if (!end) break;
    part = end + 1;
  }
  return true;
}
void wd_config_defaults(struct wd_config *c)
{
  *c = (struct wd_config){ .state_file = "/run/rtnl-watchdog.json", .metrics_file = "/run/metrics/rtnl-watchdog.prom",
    .lock_file = "/run/rtnl-watchdog.lock", .interval_ms = 1000, .threshold_ms = 1000, .tick_ms = 250, .error_backoff_ms = 5000 };
}
int wd_config_parse(struct wd_config *c, int argc, char **argv)
{
  static const struct option options[] = {
    {"state-file",1,NULL,'s'}, {"metrics-file",1,NULL,'m'}, {"lock-file",1,NULL,'l'},
    {"interval-ms",1,NULL,1}, {"threshold-ms",1,NULL,2}, {"tick-ms",1,NULL,3}, {"error-backoff-ms",1,NULL,4},
    {"help",0,NULL,'h'}, {"version",0,NULL,'v'}, {NULL,0,NULL,0}
  };
  unsigned *values[] = { &c->interval_ms, &c->threshold_ms, &c->tick_ms, &c->error_backoff_ms };
  const unsigned min[] = {100,100,50,100}, max[] = {60000,60000,1000,3600000};
  optind = 1; opterr = 0; int opt;
  while ((opt = getopt_long(argc, argv, "", options, NULL)) != -1) {
    if (opt == 'h') {
      puts("Usage: rtnl-watchdog [OPTIONS]\n"
        "Measure RTNL-path request responsiveness without taking container actions.\n"
        "  --state-file PATH          Write root-owned state JSON atomically\n"
        "  --metrics-file PATH        Write Prometheus metrics atomically\n"
        "  --lock-file PATH           Lock shared with the probe helper\n"
        "  --interval-ms N            Spacing after completion, 100..60000 (1000)\n"
        "  --threshold-ms N           Distress age, 100..60000 (1000)\n"
        "  --tick-ms N                State update interval, 50..1000 (250)\n"
        "  --error-backoff-ms N       Delay after completed errors, 100..3600000 (5000)\n"
        "The distress threshold must be at least the state update interval.\n"
        "  --help                     Show help without probing\n"
        "  --version                  Show version without probing"); return 1;
    }
    if (opt == 'v') { puts(WD_VERSION); return 1; }
    if (opt == 's') c->state_file = optarg;
    else if (opt == 'm') c->metrics_file = optarg;
    else if (opt == 'l') c->lock_file = optarg;
    else if (opt >= 1 && opt <= 4) {
      if (!*optarg || strspn(optarg, "0123456789") != strlen(optarg)) return -1;
      char *end; errno = 0; unsigned long n = strtoul(optarg, &end, 10);
      if (errno || *end || n < min[opt-1] || n > max[opt-1]) return -1;
      *values[opt-1] = n;
    } else return -1;
  }
  return optind == argc && c->threshold_ms >= c->tick_ms && clean_path(c->state_file) && clean_path(c->metrics_file) &&
    clean_path(c->lock_file) && strcmp(c->state_file,c->metrics_file) && strcmp(c->state_file,c->lock_file) &&
    strcmp(c->metrics_file,c->lock_file) ? 0 : -1;
}
