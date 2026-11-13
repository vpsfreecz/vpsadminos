/* SPDX-License-Identifier: GPL-2.0 */
#ifndef RTNL_WATCHDOG_H
#define RTNL_WATCHDOG_H
#include "protocol.h"
#include <stdbool.h>
#include <sys/types.h>
#include <sys/stat.h>
#define WD_VERSION "1.0.0"
#define WD_JSON_LIMIT 4096
#define WD_EPOCH_LIMIT 96
#define WD_NS_PER_MS 1000000ULL
#define WD_BUCKETS 8
struct wd_history { uint64_t buckets[WD_BUCKETS], responses, response_sum_ns, overdue; };
struct wd_config {
  const char *state_file, *metrics_file, *lock_file;
  unsigned interval_ms, threshold_ms, tick_ms, error_backoff_ms;
};
enum wd_state { WD_STARTING, WD_PENDING, WD_DISTRESSED, WD_HEALTHY, WD_ERROR };
enum wd_message_type { WD_REQUEST = 1, WD_STARTED, WD_COMPLETED };
struct wd_message { uint32_t type, error; uint64_t sequence, started_ns, completed_ns; };
_Static_assert(sizeof(struct wd_message) == 32, "IPC frame size");
struct wd_model {
  char boot_id[37], epoch[WD_EPOCH_LIMIT];
  enum wd_state state;
  unsigned error;
  bool inflight, has_duration, overdue_counted, completion_counted;
  uint64_t sequence, observed_ns, probe_sequence, dispatch_ns, started_ns, completed_ns, last_duration_ns;
  uint64_t errors[WD_ERROR_COUNT];
  struct wd_history history;
  double last_success_realtime, observed_realtime;
};
uint64_t wd_now(void);
double wd_realtime(void);
void wd_config_defaults(struct wd_config *config);
int wd_config_parse(struct wd_config *config, int argc, char **argv);
int wd_model_init(struct wd_model *model, const char *boot, const char *epoch);
int wd_model_rebind(struct wd_model *model, const char *boot, const char *epoch);
int wd_dispatch(struct wd_model *model, uint64_t now);
int wd_apply(struct wd_model *model, const struct wd_message *message, uint64_t now, double realtime);
void wd_completion_metrics(struct wd_model *model, const struct wd_config *config);
void wd_fail(struct wd_model *model, unsigned error);
void wd_observe(struct wd_model *model, uint64_t now, double realtime, const struct wd_config *config);
const char *wd_state_name(enum wd_state state);
const char *wd_error_name(unsigned error);
int wd_json(const struct wd_model *model, char *buffer, size_t size);
int wd_metrics(const struct wd_model *model, uint64_t drops, uint64_t failures, char *buffer, size_t size);
int wd_lock(const char *path, uid_t owner);
int wd_write_file(const char *path, const char *data, mode_t mode, uid_t owner, struct stat *identity);
void wd_remove_file(const char *path, const struct stat *identity, uid_t owner);
int wd_spawn(const char *helper, int lock_fd, pid_t *pid, int *ipc_fd);
int wd_receive(int fd, struct wd_message *message, int flags);
int wd_send(int fd, const struct wd_message *message);
#endif
