/* SPDX-License-Identifier: GPL-2.0 */
#include "core.h"
#include <time.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>

uint64_t monotonic_ns(void)
{
  struct timespec t;
  if (clock_gettime(CLOCK_MONOTONIC, &t)) abort();
  return (uint64_t)t.tv_sec * 1000000000ULL + t.tv_nsec;
}
const char *loss_name(unsigned reason)
{
  static const char *names[] = { "pending_full", "duplicate_entry", "map_read", "output", "stack_capture", "stack_output" };
  return reason < LOSS_COUNT ? names[reason] : "invalid";
}
int roots_find(const struct roots *roots, uint64_t token)
{
  if (!token) return -1;
  for (size_t i = 0; i < roots->count; i++) if (roots->roots[i].token == token) return (int)i;
  return -1;
}
bool roots_current(const struct roots *roots, uint64_t now, const struct config *cfg)
{
  return roots->valid && !roots->changing && roots->generated_ns <= now &&
    now - roots->generated_ns <= (uint64_t)cfg->mapping_max_age_ms * 1000000;
}
void frame_begin(struct frame *f, const struct roots *roots, uint64_t now, uint64_t sequence)
{
  memset(f, 0, sizeof(*f));
  f->now_ns = now; f->sequence = sequence; f->roots_count = roots->count;
  f->mapping_age_ns = now >= roots->generated_ns ? now - roots->generated_ns : UINT64_MAX;
  f->alarm = -1;
}
void frame_add(struct frame *f, const struct roots *roots, const struct pending_call *call, const struct config *cfg)
{
  /* Map iteration races live insertions. Entries newer than this frame's
   * sampling cut belong to a later frame, not an integrity failure. */
  if (call->entered_ns > f->now_ns) return;
  uint64_t age = f->now_ns - call->entered_ns;
  f->pending++;
  if (age > f->oldest_ns) f->oldest_ns = age;
  int index = roots_find(roots, call->root_token);
  if (index < 0) { f->unmapped++; return; }
  f->vps[index].pending++;
  if (age > f->vps[index].oldest_ns) f->vps[index].oldest_ns = age;
  if (age >= (uint64_t)cfg->wait_ms * 1000000) f->vps[index].mature = true;
}
void frame_finish(struct frame *f, const struct roots *roots, struct assessment *a, const struct config *cfg)
{
  for (size_t i = 0; i < roots->count; i++) { if (f->vps[i].pending) f->pending_vps++; if (f->vps[i].mature) f->eligible_vps++; }
  /* Lost observations invalidate waiter evidence; transport/stack drops only
   * affect delivery. A fresh independent output can still report this alarm. */
  if (f->loss[LOSS_PENDING_FULL] || f->loss[LOSS_DUPLICATE] || f->loss[LOSS_MAP_READ]) a->degraded = true;
  bool gap = a->previous_ns && (f->now_ns <= a->previous_ns || f->now_ns - a->previous_ns > 2500000000ULL);
  f->valid = f->valid && f->available && roots_current(roots, f->now_ns, cfg) && !a->degraded && !gap;
  /* Unknown pending roots cannot justify a healthy negative assessment. */
  if (f->unmapped && f->eligible_vps < cfg->min_vps) f->valid = false;
  if (!f->valid) a->confirmations = 0;
  else if (f->eligible_vps >= cfg->min_vps) { if (a->confirmations < cfg->confirm_frames) a->confirmations++; }
  else a->confirmations = 0;
  f->confirmations = a->confirmations;
  f->alarm = f->valid ? (a->confirmations >= cfg->confirm_frames) : -1;
  a->previous_ns = f->now_ns;
}
static void ju64(struct json_object *o, const char *key, uint64_t value)
{
  json_object_object_add(o, key, json_object_new_uint64(value));
}
struct json_object *frame_json(const struct frame *f, const struct roots *roots, const char *epoch)
{
  struct json_object *o = json_object_new_object(), *vps = json_object_new_array();
  json_object_object_add(o, "schema", json_object_new_int(1));
  json_object_object_add(o, "type", json_object_new_string("snapshot"));
  json_object_object_add(o, "epoch", json_object_new_string(epoch));
  ju64(o, "sequence", f->sequence); ju64(o, "monotonic_ns", f->now_ns);
  json_object_object_add(o, "available", json_object_new_boolean(f->available));
  json_object_object_add(o, "assessment_valid", json_object_new_boolean(f->valid));
  json_object_object_add(o, "coverage", json_object_new_string(MONITOR_COVERAGE));
  json_object_object_add(o, "owner_supported", json_object_new_boolean(false));
  ju64(o, "pending_calls", f->pending); ju64(o, "pending_vps", f->pending_vps);
  ju64(o, "oldest_pending_ms", f->oldest_ns / 1000000); ju64(o, "unmapped_pending", f->unmapped);
  ju64(o, "mapping_age_ms", f->mapping_age_ns / 1000000);
  uint64_t total = 0;
  struct json_object *loss = json_object_new_object();
  for (unsigned i = 0; i < LOSS_COUNT; i++) { total += f->loss[i]; ju64(loss, loss_name(i), f->loss[i]); }
  ju64(o, "loss_total", total); json_object_object_add(o, "loss", loss);
  json_object_object_add(o, "alarm", f->alarm < 0 ? NULL : json_object_new_boolean(f->alarm));
  for (size_t i = 0; i < roots->count; i++) {
    if (!f->vps[i].pending) continue;
    struct json_object *v = json_object_new_object();
    json_object_object_add(v, "pool", json_object_new_string(roots->roots[i].pool));
    json_object_object_add(v, "id", json_object_new_string(roots->roots[i].id));
    ju64(v, "pending_calls", f->vps[i].pending); ju64(v, "oldest_pending_ms", f->vps[i].oldest_ns / 1000000);
    json_object_array_add(vps, v);
  }
  json_object_object_add(o, "vps", vps);
  return o;
}
static void label(FILE *f, const char *s)
{
  for (; *s; s++) { if (*s == '\\' || *s == '"') fputc('\\', f); fputc(*s, f); }
}
char *frame_metrics(const struct frame *f, const struct roots *roots, double realtime)
{
  char *text = NULL; size_t len = 0; FILE *out = open_memstream(&text, &len);
  if (!out) return NULL;
#define METRIC(name, value) fprintf(out, "osctl_rtnl_monitor_" name " %.17g\n", (double)(value))
  METRIC("available", f->available); METRIC("assessment_valid", f->valid);
  METRIC("snapshot_timestamp_seconds", realtime);
  METRIC("pending_calls", f->pending); METRIC("pending_vps", f->pending_vps);
  METRIC("oldest_pending_seconds", f->oldest_ns / 1e9); METRIC("unmapped_pending", f->unmapped);
  METRIC("mapping_age_seconds", f->mapping_age_ns / 1e9);
  if (f->alarm >= 0) METRIC("alarm", f->alarm);
  for (unsigned i = 0; i < LOSS_COUNT; i++)
    fprintf(out, "osctl_rtnl_monitor_loss_total{reason=\"%s\"} %llu\n", loss_name(i), (unsigned long long)f->loss[i]);
  for (size_t i = 0; i < roots->count; i++) {
    if (!f->vps[i].pending) continue;
    fprintf(out, "osctl_rtnl_monitor_vps_pending_calls{pool=\""); label(out, roots->roots[i].pool);
    fprintf(out, "\",id=\""); label(out, roots->roots[i].id);
    fprintf(out, "\"} %llu\n", (unsigned long long)f->vps[i].pending);
    fprintf(out, "osctl_rtnl_monitor_vps_oldest_pending_seconds{pool=\""); label(out, roots->roots[i].pool);
    fprintf(out, "\",id=\""); label(out, roots->roots[i].id);
    fprintf(out, "\"} %.17g\n", f->vps[i].oldest_ns / 1e9);
  }
#undef METRIC
  if (fclose(out)) { free(text); return NULL; }
  return text;
}

int load_policy(bool requested, int (*attempt)(void *, bool), void (*discard)(void *), void *ctx, bool *downgraded)
{
  *downgraded = false;
  if (!attempt(ctx, requested)) return 0;
  discard(ctx);
  if (!requested) return -1;
  if (!attempt(ctx, false)) { *downgraded = true; return 0; }
  discard(ctx); return -1;
}
int attach_policy(void *ctx, int (*attach_one)(void *, const char *), void (*discard)(void *))
{
  /* Every producer has return and exit cleanup before it can insert a call. */
  static const char *required[] = { "task_exit", "lock_leave", "killable_leave", "refcount_leave", "lock_enter", "killable_enter", "refcount_enter" };
  for (size_t i = 0; i < sizeof(required) / sizeof(*required); i++) {
    if (attach_one(ctx, required[i])) { discard(ctx); return -1; }
  }
  return 0;
}
bool mapping_unchanged(const struct roots *before, const struct roots *after)
{
  return before->generation == after->generation && !after->changing && after->valid;
}
