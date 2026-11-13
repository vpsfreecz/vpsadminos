/* SPDX-License-Identifier: GPL-2.0 */
#define _GNU_SOURCE
#include "core.h"
#include <bpf/bpf.h>
#include <bpf/libbpf.h>
#include <bpf/btf.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/file.h>
#include <time.h>
#include <unistd.h>

struct app {
  struct config cfg;
  struct bpf_object *object;
  struct bpf_link *links[7];
  unsigned link_count;
  int pending_fd, losses_fd, stacks_fd, root_sets_fd;
  int cpu_count;
  struct ring_buffer *ring;
  struct output output;
  pthread_mutex_t roots_mutex;
  struct roots roots;
  uint64_t token_serial;
  atomic_bool stop;
  atomic_ullong local_loss[LOSS_COUNT];
  char epoch[64];
};
static volatile sig_atomic_t stopped;
static void stop_signal(int sig) { (void)sig; stopped = 1; }
static void status(struct app *a, const char *reason, const char *message, bool available)
{
  struct json_object *o = json_object_new_object();
  json_object_object_add(o, "schema", json_object_new_int(1));
  json_object_object_add(o, "type", json_object_new_string("status"));
  json_object_object_add(o, "epoch", json_object_new_string(a->epoch));
  json_object_object_add(o, "available", json_object_new_boolean(available));
  json_object_object_add(o, "assessment_valid", json_object_new_boolean(false));
  json_object_object_add(o, "alarm", NULL);
  json_object_object_add(o, "coverage", json_object_new_string(MONITOR_COVERAGE));
  json_object_object_add(o, "owner_supported", json_object_new_boolean(false));
  json_object_object_add(o, "reason", json_object_new_string(reason));
  json_object_object_add(o, "message", json_object_new_string(message));
  json_object_object_add(o, "build", json_object_new_string(MONITOR_VERSION));
  output_diagnostic(&a->output, o); json_object_put(o);
}
static int initial_error(struct app *a, const char *reason, const char *message)
{
  struct json_object *o = json_object_new_object();
  json_object_object_add(o, "schema", json_object_new_int(1));
  json_object_object_add(o, "type", json_object_new_string("status"));
  json_object_object_add(o, "available", json_object_new_boolean(false));
  json_object_object_add(o, "assessment_valid", json_object_new_boolean(false));
  json_object_object_add(o, "alarm", NULL);
  json_object_object_add(o, "owner_supported", json_object_new_boolean(false));
  json_object_object_add(o, "coverage", json_object_new_string(MONITOR_COVERAGE));
  json_object_object_add(o, "reason", json_object_new_string(reason));
  json_object_object_add(o, "message", json_object_new_string(message));
  const char *s = json_object_to_json_string_ext(o, JSON_C_TO_STRING_PLAIN);
  int flags = fcntl(STDOUT_FILENO, F_GETFL);
  if (flags >= 0) fcntl(STDOUT_FILENO, F_SETFL, flags | O_NONBLOCK);
  char line[2048]; int n = snprintf(line, sizeof(line), "%s\n", s);
  if (n > 0 && (size_t)n < sizeof(line)) { ssize_t ignored = write(STDOUT_FILENO, line, n); (void)ignored; }
  fprintf(stderr, "osctl-rtnl-monitor: %s: %s\n", reason, message);
  json_object_put(o); (void)a; return 1;
}
static int stack_record(void *ctx, void *data, size_t len)
{
  struct app *a = ctx;
  if (len != sizeof(struct stack_event)) { atomic_fetch_add(&a->local_loss[LOSS_STACK_OUTPUT], 1); return 0; }
  const struct stack_event *event = data;
  struct json_object *o = json_object_new_object(), *frames = json_object_new_array();
  json_object_object_add(o, "schema", json_object_new_int(1));
  json_object_object_add(o, "type", json_object_new_string("stack"));
  json_object_object_add(o, "epoch", json_object_new_string(a->epoch));
  json_object_object_add(o, "association", json_object_new_string("entry_time_call_sample"));
  json_object_object_add(o, "owner_supported", json_object_new_boolean(false));
  json_object_object_add(o, "pid_tgid", json_object_new_uint64(event->pid_tgid));
  json_object_object_add(o, "entered_ns", json_object_new_uint64(event->call.entered_ns));
  json_object_object_add(o, "root_token", json_object_new_uint64(event->call.root_token));
  json_object_object_add(o, "api", json_object_new_int(event->call.api));
  pthread_mutex_lock(&a->roots_mutex);
  int root = roots_find(&a->roots, event->call.root_token);
  bool current = root >= 0 && !a->roots.changing && a->roots.valid;
  json_object_object_add(o, "mapping_current", json_object_new_boolean(current));
  if (current) {
    json_object_object_add(o, "pool", json_object_new_string(a->roots.roots[root].pool));
    json_object_object_add(o, "id", json_object_new_string(a->roots.roots[root].id));
  }
  pthread_mutex_unlock(&a->roots_mutex);
  json_object_object_add(o, "stack_id", json_object_new_int(event->call.stack_id));
  uint64_t addresses[MONITOR_STACK_DEPTH]; uint32_t id = event->call.stack_id;
  if (event->call.stack_id >= 0 && !bpf_map_lookup_elem(a->stacks_fd, &id, addresses)) {
    for (unsigned i = 0; i < MONITOR_STACK_DEPTH && addresses[i]; i++) {
      char address[24]; snprintf(address, sizeof(address), "0x%llx", (unsigned long long)addresses[i]);
      json_object_array_add(frames, json_object_new_string(address));
    }
  } else atomic_fetch_add(&a->local_loss[LOSS_STACK_OUTPUT], 1);
  json_object_object_add(o, "frames", frames);
  output_diagnostic(&a->output, o); json_object_put(o); return 0;
}
static void detach(struct app *a)
{
  /* Reverse attachment order: stop producers before removing cleanup. */
  while (a->link_count) bpf_link__destroy(a->links[--a->link_count]);
  if (a->ring) { ring_buffer__free(a->ring); a->ring = NULL; }
  if (a->object) { bpf_object__close(a->object); a->object = NULL; }
}
static int load_object(struct app *a, bool stacks)
{
  a->object = bpf_object__open_file(a->cfg.object, NULL);
  if (!a->object || libbpf_get_error(a->object)) { a->object = NULL; return -1; }
  if (object_configure(a->object, &a->cfg, stacks) || bpf_object__load(a->object)) return -1;
  a->pending_fd = bpf_object__find_map_fd_by_name(a->object, "pending");
  a->losses_fd = bpf_object__find_map_fd_by_name(a->object, "losses");
  a->stacks_fd = bpf_object__find_map_fd_by_name(a->object, "stacks");
  a->root_sets_fd = bpf_object__find_map_fd_by_name(a->object, "root_sets");
  return a->pending_fd < 0 || a->losses_fd < 0 || a->stacks_fd < 0 || a->root_sets_fd < 0 ? -1 : 0;
}
static void load_discard(void *ctx) { detach(ctx); }
static int attach_one(void *ctx, const char *name)
{
  struct app *a = ctx;
  struct bpf_program *program = bpf_object__find_program_by_name(a->object, name);
  if (!program) return -1;
  struct bpf_link *link = bpf_program__attach(program);
  if (!link || libbpf_get_error(link)) return -1;
  a->links[a->link_count++] = link;
  return 0;
}
static int attach(struct app *a)
{
  if (attach_policy(a, attach_one, load_discard)) return -1;
  int fd = bpf_object__find_map_fd_by_name(a->object, "diagnostics");
  a->ring = ring_buffer__new(fd, stack_record, a, NULL);
  return !a->ring || libbpf_get_error(a->ring) ? (a->ring = NULL, -1) : 0;
}
static int publish_roots(struct app *a, const struct roots *roots)
{
  int fd = bpf_map_create(BPF_MAP_TYPE_HASH, "rtnl_roots", sizeof(struct root_key), sizeof(struct root_value), MONITOR_ROOT_MAP_ENTRIES, NULL);
  if (fd < 0) return -1;
  unsigned levels[MONITOR_LEVELS]; size_t count = 0;
  for (size_t i = 0; i < roots->count; i++) {
    struct root_key key = { .kind = 1, .id = roots->roots[i].cgid };
    struct root_value value = { .token = roots->roots[i].token, .sampling_key = root_sampling_key(&roots->roots[i]) };
    if (bpf_map_update_elem(fd, &key, &value, BPF_NOEXIST)) { close(fd); return -1; }
    bool seen = false;
    for (size_t j = 0; j < count; j++) if (levels[j] == roots->roots[i].level) seen = true;
    if (!seen) levels[count++] = roots->roots[i].level;
  }
  for (size_t i = 0; i < count; i++) {
    struct root_key key = { .kind = 0, .id = i }; struct root_value value = { .token = levels[i] };
    if (bpf_map_update_elem(fd, &key, &value, BPF_NOEXIST)) { close(fd); return -1; }
  }
  uint32_t zero = 0; int err = bpf_map_update_elem(a->root_sets_fd, &zero, &fd, BPF_ANY);
  close(fd); return err;
}
static int read_roots(struct app *a, struct roots *next)
{
  int fd = open(a->cfg.roots_file, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK);
  struct stat st;
  if (fd < 0 || fstat(fd, &st) || !S_ISREG(st.st_mode) || st.st_uid != 0 || st.st_mode & 077 || st.st_size <= 0 || st.st_size > ROOT_JSON_LIMIT) {
    if (fd >= 0) close(fd);
    snprintf(next->error, sizeof(next->error), "roots file must be a bounded root-owned0600 regular file"); return -1;
  }
  size_t len = st.st_size; char *data = malloc(len + 1);
  if (!data) { close(fd); return -1; }
  size_t got = 0;
  while (got < len) {
    ssize_t n = read(fd, data + got, len - got);
    if (n < 0 && errno == EINTR) continue;
    if (n <= 0) break;
    got += n;
  }
  close(fd); data[got] = 0;
  int err = got == len ? roots_parse(data, got, &a->cfg, next) : -1;
  free(data);
  if (!err) { char mount[PATH_MAX]; err = roots_resolve(next, mount, sizeof(mount)); }
  return err;
}
static bool same_roots(const struct roots *a, const struct roots *b)
{
  if (a->count != b->count || strcmp(a->mount, b->mount)) return false;
  for (size_t i = 0; i < a->count; i++) if (memcmp(&a->roots[i], &b->roots[i], sizeof(struct root))) return false;
  return true;
}
static void *mapping_worker(void *ctx)
{
  struct app *a = ctx;
  struct roots *next = calloc(1, sizeof(*next)), *old = calloc(1, sizeof(*old));
  if (!next || !old) { atomic_fetch_add(&a->local_loss[LOSS_MAP_READ], 1); free(next); free(old); return NULL; }
  char previous_error[192] = "";
  while (!atomic_load(&a->stop)) {
    memset(next, 0, sizeof(*next));
    if (read_roots(a, next)) {
      if (!next->error[0]) snprintf(next->error, sizeof(next->error), "roots read or resolution failed");
      pthread_mutex_lock(&a->roots_mutex); a->roots.valid = false;
      snprintf(a->roots.error, sizeof(a->roots.error), "%s", next->error); pthread_mutex_unlock(&a->roots_mutex);
      if (strcmp(previous_error, next->error)) { status(a, "mapping_invalid", next->error, true); snprintf(previous_error, sizeof(previous_error), "%s", next->error); }
    } else {
      pthread_mutex_lock(&a->roots_mutex); *old = a->roots; pthread_mutex_unlock(&a->roots_mutex);
      roots_tokens(next, old, &a->token_serial);
      bool changed = !old->valid || !same_roots(next, old);
      if (changed) {
        pthread_mutex_lock(&a->roots_mutex); a->roots.changing = true; a->roots.generation++; pthread_mutex_unlock(&a->roots_mutex);
        if (publish_roots(a, next)) {
          atomic_fetch_add(&a->local_loss[LOSS_MAP_READ], 1); next->valid = false;
          snprintf(next->error, sizeof(next->error), "root map publication failed");
        }
      }
      pthread_mutex_lock(&a->roots_mutex);
      next->generation = a->roots.generation; a->roots = *next;
      pthread_mutex_unlock(&a->roots_mutex);
      if (previous_error[0] || changed) status(a, "mapping_refreshed", "new coherent root inventory published; pre-attach waiters remain unobserved", true);
      previous_error[0] = 0;
    }
    struct timespec pause = { .tv_sec = 0, .tv_nsec = 100000000 };
    for (unsigned i = 0; i < 10 && !atomic_load(&a->stop); i++) nanosleep(&pause, NULL);
  }
  free(next); free(old); return NULL;
}
static void read_pending(struct app *a, const struct roots *roots, struct frame *f)
{
  size_t slots = 2;
  while (slots < (size_t)a->cfg.max_pending * 2) slots <<= 1;
  uint64_t key = 0, next, *seen = calloc(slots, sizeof(uint64_t));
  if (!seen) { f->loss[LOSS_MAP_READ]++; return; }
  size_t count = 0, steps = 0; bool first = true;
  while (!bpf_map_get_next_key(a->pending_fd, first ? NULL : &key, &next)) {
    first = false; key = next;
    if (++steps > (size_t)a->cfg.max_pending * 2 + 1) { f->loss[LOSS_MAP_READ]++; break; }
    size_t slot = (key * 11400714819323198485ULL) & (slots - 1);
    while (seen[slot] && seen[slot] != key) slot = (slot + 1) & (slots - 1);
    if (seen[slot] == key) continue;
    if (count == a->cfg.max_pending) { f->loss[LOSS_MAP_READ]++; break; }
    seen[slot] = key; count++;
    struct pending_call call;
    if (bpf_map_lookup_elem(a->pending_fd, &key, &call)) {
      if (errno != ENOENT) f->loss[LOSS_MAP_READ]++;
      continue;
    }
    frame_add(f, roots, &call, &a->cfg);
  }
  if (errno != ENOENT) f->loss[LOSS_MAP_READ]++;
  free(seen);
}
static void read_losses(struct app *a, struct frame *frame)
{
  uint64_t *values = calloc(a->cpu_count, sizeof(uint64_t));
  if (!values) { atomic_fetch_add(&a->local_loss[LOSS_MAP_READ], 1); frame->loss[LOSS_MAP_READ]++; return; }
  uint64_t failures = 0;
  for (uint32_t i = 0; i < LOSS_COUNT; i++) {
    if (bpf_map_lookup_elem(a->losses_fd, &i, values)) failures++;
    else for (int cpu = 0; cpu < a->cpu_count; cpu++) frame->loss[i] += values[cpu];
    frame->loss[i] += atomic_load(&a->local_loss[i]);
  }
  atomic_fetch_add(&a->local_loss[LOSS_MAP_READ], failures); frame->loss[LOSS_MAP_READ] += failures;
  frame->loss[LOSS_OUTPUT] += atomic_load(&a->output.drops) + atomic_load(&a->output.failures);
  frame->loss[LOSS_STACK_OUTPUT] += atomic_load(&a->output.diagnostic_drops);
  free(values);
}
static int load_attempt(void *ctx, bool stacks) { return load_object(ctx, stacks); }
int main(int argc, char **argv)
{
  struct app *a = calloc(1, sizeof(*a));
  if (!a) return 1;
  config_defaults(&a->cfg);
  int parsed = config_parse(&a->cfg, argc, argv);
  if (parsed == 1) { free(a); return 0; }
  if (parsed < 0) return initial_error(a, "invalid_options", "invalid options; use --help for ranges and required paths");
  if (geteuid()) return initial_error(a, "unsupported_privilege", "initial monitor requires host root privileges");
  signal(SIGINT, stop_signal); signal(SIGTERM, stop_signal); signal(SIGPIPE, SIG_IGN);
  snprintf(a->epoch, sizeof(a->epoch), "%ld-%llu", (long)getpid(), (unsigned long long)monotonic_ns());
  bool downgraded = false;
  if (load_policy(a->cfg.stacks, load_attempt, load_discard, a, &downgraded))
    return initial_error(a, "unsupported_bpf", "required waiter object/helper load failed");
  if (attach(a)) { detach(a); return initial_error(a, "unsupported_hooks", "a required hook or event attachment failed; all attached links were closed"); }
  a->cpu_count = libbpf_num_possible_cpus();
  if (a->cpu_count <= 0) { detach(a); return initial_error(a, "unsupported_cpus", "cannot determine per-CPU map layout"); }
  pthread_mutex_init(&a->roots_mutex, NULL); output_init(&a->output, a->cfg.metrics_file);
  if (output_start(&a->output)) { detach(a); return initial_error(a, "output_failure", "cannot start bounded output workers"); }
  if (downgraded) status(a, "stacks_disabled", "optional stack-enabled load failed; waiter-only load succeeded before attachment", true);
  else if (!a->cfg.stacks) status(a, "stacks_disabled", "entry-time stack diagnostics disabled by configuration", true);
  status(a, "ready", "required global blocking wrappers attached; pre-attach waiters and untraced paths excluded; owner tracking unsupported", true);
  struct btf *btf = btf__load_vmlinux_btf();
  if (!btf || libbpf_get_error(btf)) status(a, "coverage_details", "conditional per-net wrapper presence could not be inspected; no owner/all-RTNL coverage", true);
  else {
    bool present = btf__find_by_name_kind(btf, "__rtnl_net_lock", BTF_KIND_FUNC) > 0 ||
      btf__find_by_name_kind(btf, "rtnl_net_lock", BTF_KIND_FUNC) > 0;
    status(a, "coverage_details", present ? "conditional per-net wrapper present in BTF (DEBUG_NET_SMALL_RTNL path); outside coverage" : "conditional per-net wrapper absent in BTF; configuration not independently known, internal/untraced paths remain outside coverage", true);
    btf__free(btf);
  }
  pthread_t mapper;
  if (pthread_create(&mapper, NULL, mapping_worker, a)) { output_cleanup(&a->output); detach(a); return initial_error(a, "mapping_failure", "cannot start inventory worker"); }
  struct roots *roots = calloc(1, sizeof(*roots)); struct frame *frame = calloc(1, sizeof(*frame));
  if (!roots || !frame) { atomic_store(&a->stop, true); detach(a); output_cleanup(&a->output); return 1; }
  struct assessment assessment = {0}; uint64_t sequence = 0, next_frame = monotonic_ns();
  while (!stopped) {
    if (ring_buffer__poll(a->ring, 10) < 0 && errno != EINTR) atomic_fetch_add(&a->local_loss[LOSS_STACK_OUTPUT], 1);
    uint64_t now = monotonic_ns();
    if (now < next_frame) continue;
    pthread_mutex_lock(&a->roots_mutex); *roots = a->roots; pthread_mutex_unlock(&a->roots_mutex);
    frame_begin(frame, roots, now, ++sequence); frame->available = true; frame->valid = true;
    read_pending(a, roots, frame);
    atomic_fetch_add(&a->local_loss[LOSS_MAP_READ], frame->loss[LOSS_MAP_READ]);
    frame->loss[LOSS_MAP_READ] = 0;
    read_losses(a, frame);
    pthread_mutex_lock(&a->roots_mutex);
    if (!mapping_unchanged(roots, &a->roots)) frame->valid = false;
    pthread_mutex_unlock(&a->roots_mutex);
    frame_finish(frame, roots, &assessment, &a->cfg);
    struct json_object *json = frame_json(frame, roots, a->epoch);
    char *text = strdup(json_object_to_json_string_ext(json, JSON_C_TO_STRING_PLAIN)); json_object_put(json);
    struct timespec wall; clock_gettime(CLOCK_REALTIME, &wall);
    output_submit(&a->output, text, frame_metrics(frame, roots, wall.tv_sec + wall.tv_nsec / 1e9));
    next_frame = now + (uint64_t)a->cfg.interval_ms * 1000000;
  }
  atomic_store(&a->stop, true); detach(a);
  struct timespec deadline; clock_gettime(CLOCK_REALTIME, &deadline); deadline.tv_sec++;
  bool joined = pthread_timedjoin_np(mapper, NULL, &deadline) == 0;
  int drained = output_cleanup(&a->output);
  /* A stuck I/O worker is not claimed canceled; closed links cannot persist. */
  free(roots); free(frame); return joined && !drained ? 0 : 1;
}
