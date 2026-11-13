/* SPDX-License-Identifier: GPL-2.0 */
#include "core.h"
#include <getopt.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
void config_defaults(struct config *c)
{
  *c = (struct config){ .object = "/usr/local/lib/osctl-rtnl-monitor/monitor.bpf.o",
    .metrics_file = "/run/metrics/osctl-rtnl-monitor.prom", .interval_ms = 1000,
    .wait_ms = 1000, .min_vps = 3, .confirm_frames = 2, .max_pending = 4096,
    .max_roots = 1024, .mapping_max_age_ms = 30000, .stacks = true };
}
int config_parse(struct config *c, int argc, char **argv)
{
  static const struct option options[] = {
    {"roots-file", 1, NULL, 'r'}, {"bpf-object", 1, NULL, 'b'}, {"metrics-file", 1, NULL, 'm'},
    {"interval-ms", 1, NULL, 1}, {"wait-ms", 1, NULL, 2}, {"min-vps", 1, NULL, 3},
    {"confirm-frames", 1, NULL, 4}, {"max-pending", 1, NULL, 5}, {"max-roots", 1, NULL, 6},
    {"mapping-max-age-ms", 1, NULL, 7}, {"stacks", 1, NULL, 's'},
    {"help", 0, NULL, 'h'}, {"version", 0, NULL, 'v'}, {NULL, 0, NULL, 0}
  };
  unsigned *fields[] = { &c->interval_ms, &c->wait_ms, &c->min_vps, &c->confirm_frames,
    &c->max_pending, &c->max_roots, &c->mapping_max_age_ms };
  const unsigned lower[] = {100, 1, 1, 1, 1, 1, 100};
  const unsigned upper[] = {2000, 600000, 1024, 1000, 65536, 1024, 3600000};
  optind = 1; opterr = 0;
  int opt;
  while ((opt = getopt_long(argc, argv, "", options, NULL)) != -1) {
    if (opt == 'h') {
      puts("Usage: osctl-rtnl-monitor --roots-file PATH [OPTIONS]\n"
        "Observe pending global RTNL acquisition calls. No actions are taken.\n"
        "  --bpf-object PATH          Matching monitor.bpf.o\n"
        "  --metrics-file PATH        Atomic Prometheus textfile\n"
        "  --interval-ms N            Frame interval, 100..2000 (1000)\n"
        "  --wait-ms N                Minimum call age, 1..600000 (1000)\n"
        "  --min-vps N                Distinct root threshold, 1..1024 (3)\n"
        "  --confirm-frames N         Consecutive frames, 1..1000 (2)\n"
        "  --max-pending N            Task map capacity, 1..65536 (4096)\n"
        "  --max-roots N              Root capacity, 1..1024 (1024)\n"
        "  --mapping-max-age-ms N     Mapping age bound, 100..3600000 (30000)\n"
        "  --stacks entry|off         Bounded entry-time diagnostics (entry)\n"
        "  --help                     Show this help without attaching\n"
        "  --version                  Show version without attaching");
      return 1;
    }
    if (opt == 'v') { puts(MONITOR_VERSION); return 1; }
    if (opt == 'r') c->roots_file = optarg;
    else if (opt == 'b') c->object = optarg;
    else if (opt == 'm') c->metrics_file = optarg;
    else if (opt == 's') {
      if (!strcmp(optarg, "entry")) c->stacks = true;
      else if (!strcmp(optarg, "off")) c->stacks = false;
      else return -1;
    } else if (opt >= 1 && opt <= 7) {
      if (!optarg[0] || strspn(optarg, "0123456789") != strlen(optarg)) return -1;
      char *end; errno = 0; unsigned long value = strtoul(optarg, &end, 10);
      if (errno || *end || value < lower[opt - 1] || value > upper[opt - 1]) return -1;
      *fields[opt - 1] = value;
    } else return -1;
  }
  return optind == argc && c->roots_file && *c->roots_file && *c->object && *c->metrics_file ? 0 : -1;
}
