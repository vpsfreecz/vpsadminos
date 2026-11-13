/* SPDX-License-Identifier: GPL-2.0 */
#define _GNU_SOURCE
#include "output.h"
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
static void *writer(void *context)
{
  struct wd_output *o = context;
  for (;;) {
    pthread_mutex_lock(&o->mutex);
    while (!o->ready && !o->event[0] && !o->stop) pthread_cond_wait(&o->condition, &o->mutex);
    if (o->stop) { pthread_mutex_unlock(&o->mutex); break; }
    bool ready = o->ready; struct wd_model model = o->model; o->ready = false;
    char event[sizeof(o->event)]; memcpy(event, o->event, sizeof(event)); o->event[0] = 0;
    pthread_mutex_unlock(&o->mutex);
    if (ready) {
      char state[WD_JSON_LIMIT + 1], metrics[WD_JSON_LIMIT + 1];
      int n = wd_json(&model, state, sizeof(state));
      if (n < 0 || wd_write_file(o->state_path, state, 0600, 0, &o->state_identity)) atomic_fetch_add(&o->failures, 1);
      n = wd_metrics(&model, atomic_load(&o->drops), atomic_load(&o->failures), metrics, sizeof(metrics));
      if (n < 0 || wd_write_file(o->metrics_path, metrics, 0644, 0, &o->metrics_identity)) atomic_fetch_add(&o->failures, 1);
    }
    if (event[0]) {
      size_t n = strlen(event);
      if (write(STDOUT_FILENO, event, n) != (ssize_t)n) atomic_fetch_add(&o->failures, 1);
    }
  }
  return NULL;
}
int wd_output_start(struct wd_output *o, const struct wd_config *c)
{
  memset(o, 0, sizeof(*o)); o->state_path = c->state_file; o->metrics_path = c->metrics_file;
  pthread_mutex_init(&o->mutex, NULL); pthread_cond_init(&o->condition, NULL);
  int flags = fcntl(STDOUT_FILENO, F_GETFL);
  if (flags < 0 || fcntl(STDOUT_FILENO, F_SETFL, flags | O_NONBLOCK)) return -1;
  if (pthread_create(&o->thread, NULL, writer, o)) return -1;
  o->started = true; return 0;
}
void wd_output_submit(struct wd_output *o, const struct wd_model *m)
{
  pthread_mutex_lock(&o->mutex);
  if (o->ready) atomic_fetch_add(&o->drops, 1);
  o->model = *m; o->ready = true; pthread_cond_signal(&o->condition);
  pthread_mutex_unlock(&o->mutex);
}
void wd_output_event(struct wd_output *o, const char *event, const struct wd_model *model, pid_t helper)
{
  pthread_mutex_lock(&o->mutex);
  if (o->event[0]) atomic_fetch_add(&o->drops, 1);
  snprintf(o->event, sizeof(o->event), "{\"schema\":1,\"type\":\"status\",\"event\":\"%s\",\"epoch\":\"%s\",\"observer_pid\":%ld,\"helper_pid\":%ld,\"error_code\":%u,\"reason\":\"%s\"}\n",
    event, model->epoch, (long)getpid(), (long)helper, model->error, wd_error_name(model->error));
  pthread_cond_signal(&o->condition); pthread_mutex_unlock(&o->mutex);
}
int wd_output_stop(struct wd_output *o)
{
  pthread_mutex_lock(&o->mutex); o->stop = true; pthread_cond_signal(&o->condition); pthread_mutex_unlock(&o->mutex);
  struct timespec deadline; clock_gettime(CLOCK_REALTIME, &deadline); deadline.tv_sec++;
  if (o->started && pthread_timedjoin_np(o->thread, NULL, &deadline)) return -1;
  wd_remove_file(o->state_path, &o->state_identity, 0);
  wd_remove_file(o->metrics_path, &o->metrics_identity, 0);
  return 0;
}
