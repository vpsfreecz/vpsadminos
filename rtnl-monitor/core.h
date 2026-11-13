/* SPDX-License-Identifier: GPL-2.0 */
#ifndef RTNL_MONITOR_CORE_H
#define RTNL_MONITOR_CORE_H
#include "monitor.h"
#include <json-c/json.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <limits.h>
#include <sys/types.h>
#define ROOT_JSON_LIMIT (8 * 1024 * 1024)
#define NAME_LIMIT 127
#define TOKEN_LIMIT 128
struct config {
  const char *roots_file, *object, *metrics_file;
  unsigned interval_ms, wait_ms, min_vps, confirm_frames;
  unsigned max_pending, max_roots, mapping_max_age_ms;
  bool stacks;
};
struct root {
  char pool[NAME_LIMIT + 1], id[NAME_LIMIT + 1], path[PATH_MAX], run[TOKEN_LIMIT + 1];
  uint64_t cgid, token;
  unsigned level;
};
struct roots {
  char mount[PATH_MAX];
  struct root roots[MONITOR_ROOTS_LIMIT];
  size_t count;
  uint64_t generated_ns, generation;
  bool valid, changing;
  char error[192];
};
struct frame {
  uint64_t sequence, now_ns, pending, unmapped, oldest_ns, loss[LOSS_COUNT];
  uint64_t mapping_age_ns;
  bool available, valid;
  int alarm;
  unsigned confirmations;
  size_t roots_count;
  struct { uint64_t pending, oldest_ns; bool mature; } vps[MONITOR_ROOTS_LIMIT];
  uint64_t pending_vps, eligible_vps;
};
struct assessment { uint64_t previous_ns; unsigned confirmations; bool degraded; };
struct bpf_object;
/* ELF/map configuration only: no kernel load, map creation or attachment. */
int object_configure(struct bpf_object *object, const struct config *cfg, bool stacks);
int load_policy(bool requested, int (*attempt)(void *, bool), void (*discard)(void *), void *ctx, bool *downgraded);
int attach_policy(void *ctx, int (*attach_one)(void *, const char *), void (*discard)(void *));
bool mapping_unchanged(const struct roots *before, const struct roots *after);
uint64_t monotonic_ns(void);
void config_defaults(struct config *cfg);
int config_parse(struct config *cfg, int argc, char **argv);
int roots_parse(const char *data, size_t len, const struct config *cfg, struct roots *out);
int roots_resolve(struct roots *roots, char *mount_path, size_t mount_len);
void roots_tokens(struct roots *next, const struct roots *previous, uint64_t *serial);
uint64_t root_sampling_key(const struct root *root);
int roots_find(const struct roots *roots, uint64_t token);
bool roots_current(const struct roots *roots, uint64_t now, const struct config *cfg);
void frame_begin(struct frame *frame, const struct roots *roots, uint64_t now, uint64_t sequence);
void frame_add(struct frame *frame, const struct roots *roots, const struct pending_call *call, const struct config *cfg);
void frame_finish(struct frame *frame, const struct roots *roots, struct assessment *assessment, const struct config *cfg);
struct json_object *frame_json(const struct frame *frame, const struct roots *roots, const char *epoch);
char *frame_metrics(const struct frame *frame, const struct roots *roots, double realtime);
const char *loss_name(unsigned reason);
/* Two independent latest-frame slots; neither writer holds the input lock during I/O. */
struct output {
  pthread_mutex_t mutex;
  pthread_cond_t cond;
  char *json, *metrics;
  char *diagnostics[16];
  unsigned diagnostic_start, diagnostic_count;
  const char *metrics_path;
  atomic_ullong drops, diagnostic_drops, failures;
  atomic_bool stop;
  pthread_t json_thread, metrics_thread;
  bool json_started, metrics_started;
  dev_t device;
  ino_t inode;
};
void output_init(struct output *out, const char *path);
int output_start(struct output *out);
void output_submit(struct output *out, char *json, char *metrics);
void output_diagnostic(struct output *out, struct json_object *obj);
int output_cleanup(struct output *out);
#endif
