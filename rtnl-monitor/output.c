/* SPDX-License-Identifier: GPL-2.0 */
#define _GNU_SOURCE
#include "core.h"
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include <time.h>

void output_init(struct output *o, const char *path)
{
  memset(o, 0, sizeof(*o));
  pthread_mutex_init(&o->mutex, NULL); pthread_cond_init(&o->cond, NULL);
  o->metrics_path = path;
}
static char *line(const char *s)
{
  size_t n = strlen(s);
  if (n > 1024 * 1024) return NULL;
  char *p = malloc(n + 2);
  if (!p) return NULL;
  memcpy(p, s, n); p[n] = '\n'; p[n + 1] = 0; return p;
}
static void *json_writer(void *arg)
{
  struct output *o = arg;
  while (!atomic_load(&o->stop)) {
    pthread_mutex_lock(&o->mutex);
    while (!o->json && !o->diagnostic_count && !atomic_load(&o->stop)) pthread_cond_wait(&o->cond, &o->mutex);
    char *data = o->json; o->json = NULL;
    if (!data && o->diagnostic_count) {
      data = o->diagnostics[o->diagnostic_start];
      o->diagnostic_start = (o->diagnostic_start + 1) % 16; o->diagnostic_count--;
    }
    pthread_mutex_unlock(&o->mutex);
    if (!data) continue;
    size_t n = strlen(data), sent = 0;
    while (sent < n && !atomic_load(&o->stop)) {
      ssize_t written = write(STDOUT_FILENO, data + sent, n - sent);
      if (written > 0) { sent += written; continue; }
      if (written < 0 && errno == EINTR) continue;
      if (written < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
        struct pollfd p = { .fd = STDOUT_FILENO, .events = POLLOUT };
        poll(&p, 1, 100); continue;
      }
      atomic_fetch_add(&o->failures, 1); break;
    }
    free(data);
  }
  return NULL;
}
static int write_metrics(struct output *o, const char *data)
{
  char tmp[PATH_MAX], parent[PATH_MAX];
  int n = snprintf(tmp, sizeof(tmp), "%s.tmp.%ld", o->metrics_path, (long)getpid());
  if (n < 0 || (size_t)n >= sizeof(tmp)) return -1;
  snprintf(parent, sizeof(parent), "%s", o->metrics_path);
  char *slash = strrchr(parent, '/');
  if (!slash) snprintf(parent, sizeof(parent), ".");
  else if (slash == parent) slash[1] = 0;
  else *slash = 0;
  struct stat st;
  if (stat(parent, &st) || st.st_uid != geteuid() || st.st_mode & 022) return -1;
  int fd = open(tmp, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0644);
  if (fd < 0) return -1;
  size_t nbytes = strlen(data), sent = 0;
  bool ok = true;
  while (sent < nbytes) {
    ssize_t nwrite = write(fd, data + sent, nbytes - sent);
    if (nwrite < 0 && errno == EINTR) continue;
    if (nwrite <= 0) { ok = false; break; }
    sent += nwrite;
  }
  if (fstat(fd, &st)) ok = false;
  if (close(fd)) ok = false;
  if (ok && rename(tmp, o->metrics_path) == 0) {
    pthread_mutex_lock(&o->mutex); o->device = st.st_dev; o->inode = st.st_ino; pthread_mutex_unlock(&o->mutex);
    return 0;
  }
  unlink(tmp); return -1;
}
static void *metrics_writer(void *arg)
{
  struct output *o = arg;
  while (!atomic_load(&o->stop)) {
    pthread_mutex_lock(&o->mutex);
    while (!o->metrics && !atomic_load(&o->stop)) pthread_cond_wait(&o->cond, &o->mutex);
    char *data = o->metrics; o->metrics = NULL;
    pthread_mutex_unlock(&o->mutex);
    if (!data) continue;
    if (write_metrics(o, data)) atomic_fetch_add(&o->failures, 1);
    free(data);
  }
  return NULL;
}
int output_start(struct output *o)
{
  int flags = fcntl(STDOUT_FILENO, F_GETFL);
  if (flags < 0 || fcntl(STDOUT_FILENO, F_SETFL, flags | O_NONBLOCK)) return -1;
  if (pthread_create(&o->json_thread, NULL, json_writer, o)) return -1;
  o->json_started = true;
  if (pthread_create(&o->metrics_thread, NULL, metrics_writer, o)) return -1;
  o->metrics_started = true; return 0;
}
void output_submit(struct output *o, char *json, char *metrics)
{
  char *formatted = json ? line(json) : NULL; free(json);
  pthread_mutex_lock(&o->mutex);
  if (o->json) { free(o->json); atomic_fetch_add(&o->drops, 1); }
  if (o->metrics) { free(o->metrics); atomic_fetch_add(&o->drops, 1); }
  o->json = formatted; o->metrics = metrics;
  if (!formatted || !metrics) atomic_fetch_add(&o->failures, 1);
  pthread_cond_broadcast(&o->cond); pthread_mutex_unlock(&o->mutex);
}
void output_diagnostic(struct output *o, struct json_object *obj)
{
  char *data = line(json_object_to_json_string_ext(obj, JSON_C_TO_STRING_PLAIN));
  pthread_mutex_lock(&o->mutex);
  if (data && o->diagnostic_count < 16) {
    unsigned slot = (o->diagnostic_start + o->diagnostic_count) % 16;
    o->diagnostics[slot] = data; o->diagnostic_count++;
    pthread_cond_broadcast(&o->cond);
  } else { free(data); atomic_fetch_add(&o->diagnostic_drops, 1); }
  pthread_mutex_unlock(&o->mutex);
}
int output_cleanup(struct output *o)
{
  pthread_mutex_lock(&o->mutex);
  atomic_store(&o->stop, true); pthread_cond_broadcast(&o->cond);
  pthread_mutex_unlock(&o->mutex);
  struct timespec deadline; clock_gettime(CLOCK_REALTIME, &deadline); deadline.tv_sec++;
  bool complete = true;
  if (o->json_started && pthread_timedjoin_np(o->json_thread, NULL, &deadline)) complete = false;
  clock_gettime(CLOCK_REALTIME, &deadline); deadline.tv_sec++;
  if (o->metrics_started && pthread_timedjoin_np(o->metrics_thread, NULL, &deadline)) complete = false;
  /* A failed drain is not a clean exit: retain timestamped output instead of
   * claiming an unfinished filesystem writer has been canceled. */
  if (!complete) return -1;
  struct stat st;
  if (o->inode && !lstat(o->metrics_path, &st) && st.st_dev == o->device && st.st_ino == o->inode) unlink(o->metrics_path);
  return 0;
}
