/* SPDX-License-Identifier: GPL-2.0 */
#define _GNU_SOURCE
#include "output.h"
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>
#ifndef WD_HELPER_PATH
#define WD_HELPER_PATH "/usr/local/libexec/rtnl-watchdog-probe"
#endif
static volatile sig_atomic_t stopping;
static void stop_signal(int signal) { (void)signal; stopping = 1; }
static int failure(const char *event, unsigned error)
{
  char text[256]; int n = snprintf(text, sizeof(text), "{\"schema\":1,\"type\":\"status\",\"event\":\"%s\",\"error_code\":%u}\n", event, error);
  int flags = fcntl(STDERR_FILENO, F_GETFL);
  if (flags >= 0) fcntl(STDERR_FILENO, F_SETFL, flags | O_NONBLOCK);
  if (n > 0 && n < (int)sizeof(text)) { ssize_t ignored = write(STDERR_FILENO, text, n); (void)ignored; }
  return 1;
}
static int read_boot(char *boot)
{
  int fd = open("/proc/sys/kernel/random/boot_id", O_RDONLY | O_CLOEXEC);
  if (fd < 0) return -1;
  char text[64]; ssize_t n = read(fd, text, sizeof(text)); close(fd);
  if (n != 37 || text[36] != '\n') return -1;
  memcpy(boot, text, 36); boot[36] = 0; return 0;
}
static int epoch(struct wd_model *model, const char *boot, pid_t child, uint64_t now)
{
  char id[WD_EPOCH_LIMIT]; snprintf(id, sizeof(id), "%ld-%ld-%" PRIu64, (long)getpid(), (long)child, now);
  return wd_model_rebind(model, boot, id);
}
static void standard_fds(void)
{
  for (int i = 0; i < 3; i++) {
    if (fcntl(i, F_GETFD) >= 0 || errno != EBADF) continue;
    int fd = open("/dev/null", O_RDWR);
    if (fd >= 0 && fd != i) { dup2(fd, i); close(fd); }
  }
}
int main(int argc, char **argv)
{
  struct wd_config config; wd_config_defaults(&config);
  int parsed = wd_config_parse(&config, argc, argv);
  if (parsed == 1) return 0;
  if (parsed < 0) return failure("invalid_options", WD_IPC);
  if (geteuid()) return failure("root_required", WD_IPC);
  standard_fds();
  int lock = wd_lock(config.lock_file, 0);
  if (lock < 0) return failure("lifetime_lock_unavailable", WD_CHILD);
  char boot[37]; struct wd_model model = {0};
  if (read_boot(boot) || epoch(&model, boot, 0, wd_now())) { close(lock); return failure("invalid_boot_identity", WD_IPC); }
  signal(SIGINT, stop_signal); signal(SIGTERM, stop_signal); signal(SIGPIPE, SIG_IGN); signal(SIGCHLD, SIG_DFL);
  struct wd_output *output = calloc(1, sizeof(*output));
  if (!output || wd_output_start(output, &config)) { close(lock); return failure("output_start_failed", WD_IPC); }
  pid_t child = 0; int ipc = -1;
  uint64_t next_probe = wd_now(), next_frame = next_probe;
  uint64_t interval = (uint64_t)config.interval_ms * WD_NS_PER_MS;
  uint64_t backoff = (uint64_t)config.error_backoff_ms * WD_NS_PER_MS;
  if (backoff < interval) backoff = interval;
  enum wd_state previous = WD_STARTING;
  while (!stopping) {
    uint64_t now = wd_now();
    if (child) {
      int status; pid_t reaped = waitpid(child, &status, WNOHANG);
      if (reaped == child) {
        if (ipc >= 0) close(ipc);
        ipc = -1; wd_output_event(output, "helper_reaped", &model, child);
        child = 0; model.inflight = false; wd_fail(&model, WD_CHILD); next_probe = now + backoff;
      } else if (reaped < 0 && errno != EINTR && model.error != WD_CHILD) {
        /* An unexpected wait failure is uncertainty, not permission to spawn. */
        if (ipc >= 0) close(ipc);
        ipc = -1; wd_fail(&model, WD_CHILD);
      }
    }
    if (ipc >= 0) {
      for (unsigned i = 0; i < 4; i++) {
        struct wd_message message; int received = wd_receive(ipc, &message, MSG_DONTWAIT);
        if (received < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR)) break;
        now = wd_now();
        int result = received == 1 ? wd_apply(&model, &message, now, wd_realtime()) : -1;
        if (received != 1) wd_fail(&model, WD_IPC);
        if (result < 0) { close(ipc); ipc = -1; break; }
        if (result == 1) { wd_completion_metrics(&model, &config); next_probe = now + (model.error ? backoff : interval); }
      }
    }
    now = wd_now();
    if (!child && now >= next_probe) {
      int result = wd_spawn(WD_HELPER_PATH, lock, &child, &ipc);
      if (child) {
        epoch(&model, boot, child, now); previous = WD_STARTING;
        wd_output_event(output, "helper_started", &model, child);
      }
      if (result) { wd_fail(&model, WD_CHILD); next_probe = now + backoff; }
      else next_probe = now;
    }
    if (child && ipc >= 0 && !model.inflight && now >= next_probe) {
      if (!wd_dispatch(&model, now)) {
        struct wd_message request = { .type = WD_REQUEST, .sequence = model.probe_sequence };
        if (wd_send(ipc, &request)) { wd_fail(&model, WD_IPC); close(ipc); ipc = -1; }
      }
    }
    now = wd_now();
    /* Completion/state transitions publish immediately; unchanged states have
     * the configured heartbeat. There is no request or output backlog. */
    if (now >= next_frame || model.state != previous) {
      wd_observe(&model, now, wd_realtime(), &config);
      if (model.state != previous) wd_output_event(output, wd_state_name(model.state), &model, child);
      previous = model.state; wd_output_submit(output, &model);
      next_frame = now + (uint64_t)config.tick_ms * WD_NS_PER_MS;
    }
    uint64_t due = next_frame;
    if ((!child || (ipc >= 0 && !model.inflight)) && next_probe < due) due = next_probe;
    now = wd_now(); int delay = due <= now ? 0 : (int)((due - now + WD_NS_PER_MS - 1) / WD_NS_PER_MS);
    struct pollfd descriptor = { .fd = ipc, .events = POLLIN };
    poll(ipc >= 0 ? &descriptor : NULL, ipc >= 0 ? 1 : 0, delay);
  }
  if (ipc >= 0) close(ipc); /* Outstanding sendmsg is not canceled. */
  wd_output_event(output, "observer_stopping", &model, child);
  int drained = wd_output_stop(output);
  if (child) {
    int status;
    if (waitpid(child, &status, WNOHANG) == 0) failure("helper_outstanding_lock_retained", WD_CHILD);
  }
  close(lock); /* Closing our description never explicitly unlocks the child. */
  return drained ? 1 : 0;
}
