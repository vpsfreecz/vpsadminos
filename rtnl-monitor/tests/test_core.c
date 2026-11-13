/* SPDX-License-Identifier: GPL-2.0 */
#include "core.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const char *manifest = "{\"schema\":1,\"generated_monotonic_ns\":1000000000,\"cgroup_mount\":\"/sys/fs/cgroup\",\"roots\":[{\"pool\":\"pool\",\"id\":\"a\",\"path\":\"osctl/pool.pool/ct.a\",\"run_token\":\"run-a\"}]}";
static void parse_tests(struct config *c, struct roots *r)
{
  assert(!roots_parse(manifest, strlen(manifest), c, r));
  assert(r->count == 1 && r->roots[0].level == 3);
  const char *bad[] = {
    "{}", "null", "{\"schema\":2}",
    "{\"schema\":1,\"generated_monotonic_ns\":1,\"cgroup_mount\":\"/cg\",\"roots\":false}",
    "{\"schema\":1,\"generated_monotonic_ns\":-1,\"cgroup_mount\":\"/cg\",\"roots\":[]}",
    "{\"schema\":1,\"generated_monotonic_ns\":1,\"cgroup_mount\":\"/cg\",\"roots\":[{\"pool\":\"x\",\"id\":\"a\",\"path\":\"../escape\",\"run_token\":\"r\"}]}",
    "{\"schema\":1,\"generated_monotonic_ns\":1,\"cgroup_mount\":\"/cg\",\"roots\":[{\"pool\":\"x\",\"id\":\"a\",\"path\":\"a\",\"run_token\":\"r\"},{\"pool\":\"x\",\"id\":\"b\",\"path\":\"a/child\",\"run_token\":\"s\"}]}",
    "{\"schema\":1,\"generated_monotonic_ns\":1,\"cgroup_mount\":\"/cg\",\"roots\":[{\"pool\":\"x\",\"id\":\"a\",\"path\":\"a\",\"run_token\":\"r\"},{\"pool\":\"x\",\"id\":\"a\",\"path\":\"b\",\"run_token\":\"s\"}]}"
  };
  for (size_t i = 0; i < sizeof(bad) / sizeof(*bad); i++) assert(roots_parse(bad[i], strlen(bad[i]), c, r) < 0);
  char *trailing = malloc(strlen(manifest) + 3); sprintf(trailing, "%sX", manifest);
  assert(roots_parse(trailing, strlen(trailing), c, r) < 0); free(trailing);
  assert(!roots_parse(manifest, strlen(manifest), c, r));
  /* The logical inventory limit is independent of fixed physical map size. */
  struct json_object *obj = json_tokener_parse(manifest), *array;
  assert(obj && json_object_object_get_ex(obj, "roots", &array));
  json_object_array_add(array, json_tokener_parse("{\"pool\":\"pool\",\"id\":\"b\",\"path\":\"osctl/pool.pool/ct.b\",\"run_token\":\"run-b\"}"));
  const char *two = json_object_to_json_string_ext(obj, JSON_C_TO_STRING_PLAIN);
  c->max_roots = 1; assert(roots_parse(two, strlen(two), c, r) < 0);
  c->max_roots = 2; assert(!roots_parse(two, strlen(two), c, r) && r->count == 2);
  c->max_roots = MONITOR_ROOTS_LIMIT; json_object_put(obj);
  assert(!roots_parse(manifest, strlen(manifest), c, r));
}
static void token_tests(struct config *c, struct roots *a, struct roots *b)
{
  uint64_t serial = 0;
  assert(!roots_parse(manifest, strlen(manifest), c, a));
  a->roots[0].cgid = 100;
  memset(b, 0, sizeof(*b)); roots_tokens(a, b, &serial);
  assert(a->roots[0].token == 1);
  *b = *a; b->generated_ns++;
  roots_tokens(b, a, &serial); assert(b->roots[0].token == 1);
  uint64_t sampling = root_sampling_key(&a->roots[0]);
  strcpy(b->roots[0].run, "replacement");
  roots_tokens(b, a, &serial); assert(b->roots[0].token == 2 && root_sampling_key(&b->roots[0]) == sampling);
  assert(roots_find(b, a->roots[0].token) < 0);
  *a = *b; b->roots[0].cgid++;
  roots_tokens(b, a, &serial); assert(b->roots[0].token == 3);
}
static void roots_fixture(struct roots *r)
{
  memset(r, 0, sizeof(*r)); r->count = 3; r->valid = true; r->generated_ns = 1000000000ULL;
  for (unsigned i = 0; i < 3; i++) {
    r->roots[i].token = i + 1;
    strcpy(r->roots[i].pool, "p"); snprintf(r->roots[i].id, sizeof(r->roots[i].id), "%u", i);
  }
}
static void add_three(struct frame *f, struct roots *r, struct config *c)
{
  for (unsigned i = 0; i < 3; i++) {
    struct pending_call call = { .entered_ns = 1000000000ULL, .root_token = i + 1 };
    frame_add(f, r, &call, c);
  }
}
static void assessment_tests(struct config *c, struct roots *r, struct frame *f)
{
  roots_fixture(r); struct assessment a = {0};
  frame_begin(f, r, 2000000000ULL, 1); f->available = f->valid = true;
  add_three(f, r, c); add_three(f, r, c); frame_finish(f, r, &a, c);
  assert(f->pending == 6 && f->pending_vps == 3 && f->eligible_vps == 3 && f->alarm == 0);
  frame_begin(f, r, 3000000000ULL, 2); f->available = f->valid = true;
  add_three(f, r, c); frame_finish(f, r, &a, c); assert(f->alarm == 1);
  /* A gap cannot preserve a confirmed alarm. */
  frame_begin(f, r, 6000000000ULL, 3); f->available = f->valid = true;
  add_three(f, r, c); frame_finish(f, r, &a, c); assert(f->alarm == -1 && !a.confirmations);
  frame_begin(f, r, 7000000000ULL, 4); f->available = f->valid = true;
  add_three(f, r, c); frame_finish(f, r, &a, c); assert(f->alarm == 0);
  /* Diagnostic stack failure leaves waiter-only assessment available. */
  frame_begin(f, r, 8000000000ULL, 5); f->available = f->valid = true; f->loss[LOSS_STACK_CAPTURE] = 1;
  add_three(f, r, c); frame_finish(f, r, &a, c); assert(f->alarm == 1);
  /* Integrity loss remains degraded even after a later frame has no new loss. */
  frame_begin(f, r, 9000000000ULL, 6); f->available = f->valid = true; f->loss[LOSS_DUPLICATE] = 1;
  add_three(f, r, c); frame_finish(f, r, &a, c); assert(f->alarm == -1);
  frame_begin(f, r, 10000000000ULL, 7); f->available = f->valid = true;
  add_three(f, r, c); frame_finish(f, r, &a, c); assert(f->alarm == -1 && a.degraded);
  a = (struct assessment){0};
  frame_begin(f, r, 32000000000ULL, 1); f->available = f->valid = true;
  add_three(f, r, c); frame_finish(f, r, &a, c); assert(f->alarm == -1); /* stale mapping */
  a = (struct assessment){0}; r->generated_ns = 2000000000ULL;
  frame_begin(f, r, 1000000000ULL, 1); f->available = f->valid = true;
  frame_finish(f, r, &a, c); assert(f->alarm == -1); /* future mapping */
  roots_fixture(r); a = (struct assessment){0};
  frame_begin(f, r, 2000000000ULL, 1); f->available = f->valid = true;
  struct pending_call old = { .entered_ns = 1000000000ULL, .root_token = 99 };
  frame_add(f, r, &old, c); frame_finish(f, r, &a, c);
  assert(f->unmapped == 1 && !f->pending_vps && f->alarm == -1);
  /* A coherent-map swap crossed by a frame is explicitly invalid. */
  frame_begin(f, r, 2000000000ULL, 2); f->available = true; f->valid = false;
  add_three(f, r, c); frame_finish(f, r, &a, c); assert(f->alarm == -1);
  /* Return/exit removes the call from the next observed frame, not a TTL. */
  frame_begin(f, r, 2100000000ULL, 3); f->available = f->valid = true;
  frame_finish(f, r, &a, c); assert(!f->pending && !f->pending_vps && f->alarm == 0);
  frame_begin(f, r, 2200000000ULL, 4); f->available = f->valid = true;
  struct pending_call future = { .entered_ns = 2300000000ULL, .root_token = 1 };
  frame_add(f, r, &future, c); frame_finish(f, r, &a, c);
  assert(f->alarm == 0 && !f->pending && !a.degraded);
  frame_begin(f, r, 2400000000ULL, 5); f->available = f->valid = true;
  frame_add(f, r, &future, c); frame_finish(f, r, &a, c);
  assert(f->pending == 1 && f->pending_vps == 1 && f->alarm == 0);
}
static void output_tests(struct roots *r, struct frame *f)
{
  f->valid = false; f->alarm = -1;
  struct json_object *j = frame_json(f, r, "epoch"), *v;
  assert(json_object_object_get_ex(j, "alarm", &v) && !v);
  assert(json_object_object_get_ex(j, "owner_supported", &v) && !json_object_get_boolean(v));
  char *metrics = frame_metrics(f, r, 123.0); assert(metrics);
  assert(!strstr(metrics, "osctl_rtnl_monitor_alarm "));
  assert(strstr(metrics, "snapshot_timestamp_seconds 123")); free(metrics);
  struct output o; output_init(&o, "/unused");
  /* No output worker: a faithful blocked-consumer seam, bounded to latest slots. */
  for (unsigned i = 0; i < 100; i++) output_submit(&o, strdup("{}"), strdup("x\n"));
  assert(atomic_load(&o.drops) == 198);
  for (unsigned i = 0; i < 100; i++) output_diagnostic(&o, j);
  assert(o.diagnostic_count == 16 && atomic_load(&o.diagnostic_drops) == 84);
  free(o.json); free(o.metrics);
  for (unsigned i = 0; i < o.diagnostic_count; i++) free(o.diagnostics[i]);
  json_object_put(j);
}
static void loss_classification_tests(struct config *c, struct roots *r, struct frame *f)
{
  roots_fixture(r);
  const unsigned critical[] = { LOSS_PENDING_FULL, LOSS_DUPLICATE, LOSS_MAP_READ };
  for (size_t i = 0; i < sizeof(critical) / sizeof(*critical); i++) {
    struct assessment a = {0};
    for (unsigned n = 0; n < 2; n++) {
      frame_begin(f, r, (2ULL + n) * 1000000000, n + 1); f->available = f->valid = true;
      if (!n) f->loss[critical[i]] = 1;
      add_three(f, r, c); frame_finish(f, r, &a, c);
      assert(a.degraded && !f->valid && f->alarm == -1);
    }
  }
  struct assessment a = {0};
  for (unsigned n = 0; n < 3; n++) {
    frame_begin(f, r, (2ULL + n) * 1000000000, n + 1); f->available = f->valid = true;
    f->loss[LOSS_OUTPUT] = n + 1; f->loss[LOSS_STACK_CAPTURE] = f->loss[LOSS_STACK_OUTPUT] = 1;
    add_three(f, r, c); frame_finish(f, r, &a, c);
    assert(!a.degraded && f->valid && f->pending_vps == 3 && f->alarm == (n > 0));
  }
  struct json_object *j = frame_json(f, r, "output-test"), *v, *loss;
  assert(json_object_object_get_ex(j, "assessment_valid", &v) && json_object_get_boolean(v));
  assert(json_object_object_get_ex(j, "alarm", &v) && json_object_get_boolean(v));
  assert(json_object_object_get_ex(j, "loss", &loss));
  assert(json_object_object_get_ex(loss, "output", &v) && json_object_get_uint64(v) == 3);
  char *metrics = frame_metrics(f, r, 123.0); assert(metrics);
  assert(strstr(metrics, "osctl_rtnl_monitor_assessment_valid 1\n"));
  assert(strstr(metrics, "osctl_rtnl_monitor_alarm 1\n"));
  assert(strstr(metrics, "osctl_rtnl_monitor_loss_total{reason=\"output\"} 3\n"));
  assert(strstr(metrics, "snapshot_timestamp_seconds 123\n"));
  free(metrics); json_object_put(j);
  /* Transport-only classification must not weaken gaps or stale inventory. */
  for (unsigned n = 0; n < 3; n++) {
    frame_begin(f, r, (7ULL + n) * 1000000000, n + 4); f->available = f->valid = true;
    f->loss[LOSS_OUTPUT] = 4;
    add_three(f, r, c); frame_finish(f, r, &a, c);
    assert(f->alarm == (n == 0 ? -1 : n == 1 ? 0 : 1));
  }
  frame_begin(f, r, 32000000000ULL, 7); f->available = f->valid = true; f->loss[LOSS_OUTPUT] = 4;
  add_three(f, r, c); frame_finish(f, r, &a, c);
  assert(!f->valid && f->alarm == -1 && !a.confirmations && !a.degraded);
}
struct fake_attach {
  bool enter[3], leave[3], exit, held[3];
  unsigned attempts, fail_at, discarded, stale;
};
static int fake_attach_one(void *ctx, const char *name)
{
  struct fake_attach *f = ctx;
  if (f->attempts++ == f->fail_at) return -1;
  if (!strcmp(name, "task_exit")) f->exit = true;
  else {
    const char *apis[] = { "lock", "killable", "refcount" };
    bool found = false;
    for (unsigned i = 0; i < 3; i++) {
      char hook[32]; snprintf(hook, sizeof(hook), "%s_enter", apis[i]);
      if (!strcmp(name, hook)) { f->enter[i] = true; f->held[i] = true; found = true; }
      snprintf(hook, sizeof(hook), "%s_leave", apis[i]);
      if (!strcmp(name, hook)) { f->leave[i] = true; found = true; }
    }
    assert(found);
  }
  /* Adversarial lifetimes between every pair of actual production attaches:
   * a short call returns; another returns and exits before the next attach. */
  for (unsigned i = 0; i < 3; i++) {
    bool pending = f->enter[i];
    if (f->leave[i]) pending = false;
    if (pending) f->stale++;
    pending = f->enter[i];
    if (f->leave[i]) pending = false;
    if (f->exit) pending = false;
    if (pending) f->stale++;
  }
  return 0;
}
static void fake_attach_discard(void *ctx)
{
  struct fake_attach *f = ctx;
  f->discarded++;
  memset(f->enter, 0, sizeof(f->enter)); memset(f->leave, 0, sizeof(f->leave));
  memset(f->held, 0, sizeof(f->held)); f->exit = false;
}
static void attach_tests(void)
{
  struct fake_attach f = { .fail_at = 7 };
  assert(!attach_policy(&f, fake_attach_one, fake_attach_discard));
  assert(f.attempts == 7 && !f.discarded && !f.stale && f.exit);
  for (unsigned i = 0; i < 3; i++) {
    /* Startup does not clear a genuinely still-blocked call. Return/exit
     * cleanup is active when that call eventually completes. */
    assert(f.enter[i] && f.leave[i] && f.held[i]);
    if (f.leave[i]) f.held[i] = false;
    assert(!f.held[i]);
  }
  for (unsigned fail = 0; fail < 7; fail++) {
    f = (struct fake_attach){ .fail_at = fail };
    assert(attach_policy(&f, fake_attach_one, fake_attach_discard) < 0);
    assert(f.attempts == fail + 1 && f.discarded == 1 && !f.stale && !f.exit);
    for (unsigned i = 0; i < 3; i++) assert(!f.enter[i] && !f.leave[i] && !f.held[i]);
  }
}
static void options_tests(void)
{
  struct config c; config_defaults(&c);
  char *valid[] = {"monitor", "--roots-file", "/roots", "--bpf-object", "/one", "--bpf-object", "/two", "--interval-ms", "100", "--stacks", "off"};
  assert(!config_parse(&c, 11, valid) && !strcmp(c.object, "/two") && !c.stacks);
  const char *bad[] = {"-1", "0", "nan", "100x", "9999999999999999999999999999999", "2001"};
  for (unsigned i = 0; i < sizeof(bad) / sizeof(*bad); i++) {
    config_defaults(&c); char *args[] = {"monitor", "--roots-file", "/r", "--interval-ms", (char *)bad[i]};
    assert(config_parse(&c, 5, args) < 0);
  }
}
struct fake_load { unsigned calls, discarded; bool required_failure; };
static int fake_attempt(void *ctx, bool stacks)
{
  struct fake_load *f = ctx; f->calls++;
  return stacks || f->required_failure ? -1 : 0;
}
static void fake_discard(void *ctx) { ((struct fake_load *)ctx)->discarded++; }
static void load_tests(struct roots *a, struct roots *b)
{
  bool downgraded; struct fake_load f = {0};
  assert(!load_policy(true, fake_attempt, fake_discard, &f, &downgraded));
  assert(downgraded && f.calls == 2 && f.discarded == 1);
  f = (struct fake_load){ .required_failure = true };
  assert(load_policy(true, fake_attempt, fake_discard, &f, &downgraded) < 0);
  assert(!downgraded && f.calls == 2 && f.discarded == 2);
  f = (struct fake_load){ .required_failure = true };
  assert(load_policy(false, fake_attempt, fake_discard, &f, &downgraded) < 0);
  assert(f.calls == 1 && f.discarded == 1);
  roots_fixture(a); *b = *a; assert(mapping_unchanged(a, b));
  b->changing = true; assert(!mapping_unchanged(a, b));
  b->changing = false; b->generation++; assert(!mapping_unchanged(a, b));
  b->generation--; b->valid = false; assert(!mapping_unchanged(a, b));
}
int main(void)
{
  struct config c; config_defaults(&c);
  struct roots *a = calloc(1, sizeof(*a)), *b = calloc(1, sizeof(*b));
  struct frame *f = calloc(1, sizeof(*f)); assert(a && b && f);
  parse_tests(&c, a); token_tests(&c, a, b); assessment_tests(&c, a, f); output_tests(a, f);
  loss_classification_tests(&c, a, f); attach_tests(); options_tests(); load_tests(a, b);
  free(a); free(b); free(f); puts("core tests passed"); return 0;
}
