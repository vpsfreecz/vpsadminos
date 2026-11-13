/* SPDX-License-Identifier: GPL-2.0 */
#ifndef RTNL_WATCHDOG_OUTPUT_H
#define RTNL_WATCHDOG_OUTPUT_H
#include "watchdog.h"
#include <pthread.h>
#include <stdatomic.h>
struct wd_output {
  pthread_mutex_t mutex;
  pthread_cond_t condition;
  pthread_t thread;
  bool ready, stop, started;
  struct wd_model model;
  char event[512];
  const char *state_path, *metrics_path;
  struct stat state_identity, metrics_identity;
  atomic_ullong drops, failures;
};
int wd_output_start(struct wd_output *output, const struct wd_config *config);
void wd_output_submit(struct wd_output *output, const struct wd_model *model);
void wd_output_event(struct wd_output *output, const char *event, const struct wd_model *model, pid_t helper);
int wd_output_stop(struct wd_output *output);
#endif
