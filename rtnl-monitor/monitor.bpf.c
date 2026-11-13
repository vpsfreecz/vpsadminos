/* SPDX-License-Identifier: GPL-2.0 */
#include "vmlinux.h"
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_tracing.h>
#define __BPF__ 1
#include "monitor.h"
char LICENSE[] SEC("license") = "GPL";
const volatile struct monitor_rodata options = { .stacks_enabled = 1 };
struct {
  __uint(type, BPF_MAP_TYPE_HASH);
  __uint(max_entries, 4096);
  __type(key, __u64);
  __type(value, struct pending_call);
} pending SEC(".maps");
struct inner_roots {
  __uint(type, BPF_MAP_TYPE_HASH);
  __uint(max_entries, MONITOR_ROOT_MAP_ENTRIES);
  __type(key, struct root_key);
  __type(value, struct root_value);
} root_template SEC(".maps");
struct {
  __uint(type, BPF_MAP_TYPE_ARRAY_OF_MAPS);
  __uint(max_entries, 1);
  __type(key, __u32);
  __array(values, struct inner_roots);
} root_sets SEC(".maps") = { .values = { [0] = &root_template } };
struct {
  __uint(type, BPF_MAP_TYPE_PERCPU_ARRAY);
  __uint(max_entries, LOSS_COUNT);
  __type(key, __u32);
  __type(value, __u64);
} losses SEC(".maps");
struct {
  __uint(type, BPF_MAP_TYPE_STACK_TRACE);
  __uint(max_entries, MONITOR_STACKS);
  __uint(key_size, sizeof(__u32));
  __uint(value_size, MONITOR_STACK_DEPTH * sizeof(__u64));
} stacks SEC(".maps");
struct budget { __u64 state; };
struct {
  __uint(type, BPF_MAP_TYPE_ARRAY);
  __uint(max_entries, 1);
  __type(key, __u32);
  __type(value, struct budget);
} stack_budget SEC(".maps");
struct {
  __uint(type, BPF_MAP_TYPE_HASH);
  __uint(max_entries, 4096);
  __type(key, __u64);
  __type(value, __u64);
} root_budget SEC(".maps");
struct {
  __uint(type, BPF_MAP_TYPE_RINGBUF);
  __uint(max_entries, 65536);
} diagnostics SEC(".maps");
static __always_inline void lost(__u32 reason)
{
  __u64 *v = bpf_map_lookup_elem(&losses, &reason);
  if (v) (*v)++;
}
static __always_inline struct root_value root_token(void)
{
  __u32 zero = 0;
  void *roots = bpf_map_lookup_elem(&root_sets, &zero);
  struct root_value token = {};
  __u64 best_level = 0;
  if (!roots) return token;
#pragma unroll
  for (int i = 0; i < MONITOR_LEVELS; i++) {
    struct root_key lk = { .kind = 0, .id = i };
    struct root_value *level = bpf_map_lookup_elem(roots, &lk);
    if (!level || level->token == 0 || level->token > 255) continue;
    __u64 depth = level->token;
    __u64 id = bpf_get_current_ancestor_cgroup_id(depth);
    struct root_key rk = { .kind = 1, .id = id };
    struct root_value *found = bpf_map_lookup_elem(roots, &rk);
    if (found && depth > best_level) {
      best_level = depth;
      token = *found;
    }
  }
  return token;
}
static __always_inline int sample_allowed(__u64 token, __u64 now)
{
  __u32 zero = 0;
  struct budget *budget = bpf_map_lookup_elem(&stack_budget, &zero);
  __u64 window = now / MONITOR_STACK_WINDOW_NS + 1;
  int allowed = 0;
  if (!budget) return 0;
  /* Atomic reservation: low three bits are count, upper bits identify window.
   * No BPF spin lock is required in a tracing program. */
#pragma unroll
  for (int i = 0; i < 8; i++) {
    __u64 old = budget->state;
    /* An entry delayed across a bucket boundary cannot move the budget back. */
    if ((old >> 3) > window) break;
    __u64 count = (old >> 3) == window ? old & 7 : 0;
    if (count >= 4) break;
    __u64 next = (window << 3) | (count + 1);
    if (__sync_val_compare_and_swap(&budget->state, old, next) == old) {
      allowed = 1;
      break;
    }
  }
  if (!allowed) return 0;
  /* A new global reservation is spent even when this root was already seen. */
  __u64 *seen = bpf_map_lookup_elem(&root_budget, &token);
  if (seen && *seen >= window) return 0;
  /* BPF_NOEXIST protects simultaneous first entries for the same root. */
  if (!seen) {
    long error = bpf_map_update_elem(&root_budget, &token, &window, BPF_NOEXIST);
    if (error) { if (error != -17) lost(LOSS_STACK_CAPTURE); return 0; }
  } else {
    __u64 previous = *seen;
    if (previous >= window || __sync_val_compare_and_swap(seen, previous, window) != previous) return 0;
  }
  return 1;
}
static __always_inline int enter(void *ctx, __u32 api)
{
  __u64 key = bpf_get_current_pid_tgid();
  struct root_value root = root_token();
  struct pending_call call = {
    .entered_ns = bpf_ktime_get_ns(),
    .leaf_cgroup_id = bpf_get_current_cgroup_id(),
    .root_token = root.token, .api = api, .stack_id = -1
  };
  if (bpf_map_lookup_elem(&pending, &key)) { lost(LOSS_DUPLICATE); return 0; }
  if (options.stacks_enabled && sample_allowed(root.sampling_key, call.entered_ns)) {
    call.stack_id = bpf_get_stackid(ctx, &stacks, 0);
    if (call.stack_id < 0) lost(LOSS_STACK_CAPTURE);
    else {
      struct stack_event *event = bpf_ringbuf_reserve(&diagnostics, sizeof(*event), 0);
      if (event) { event->pid_tgid = key; event->call = call; bpf_ringbuf_submit(event, 0); }
      else lost(LOSS_STACK_OUTPUT);
    }
  }
  if (bpf_map_update_elem(&pending, &key, &call, BPF_NOEXIST)) lost(LOSS_PENDING_FULL);
  return 0;
}
static __always_inline int leave(void)
{
  __u64 key = bpf_get_current_pid_tgid();
  bpf_map_delete_elem(&pending, &key);
  return 0;
}
SEC("fentry/rtnl_lock") int BPF_PROG(lock_enter) { return enter(ctx, API_LOCK); }
SEC("fexit/rtnl_lock") int BPF_PROG(lock_leave) { return leave(); }
SEC("fentry/rtnl_lock_killable") int BPF_PROG(killable_enter) { return enter(ctx, API_KILLABLE); }
SEC("fexit/rtnl_lock_killable") int BPF_PROG(killable_leave) { return leave(); }
SEC("fentry/refcount_dec_and_rtnl_lock") int BPF_PROG(refcount_enter) { return enter(ctx, API_REFCOUNT); }
SEC("fexit/refcount_dec_and_rtnl_lock") int BPF_PROG(refcount_leave) { return leave(); }
SEC("tracepoint/sched/sched_process_exit") int task_exit(void *ctx) { (void)ctx; return leave(); }
