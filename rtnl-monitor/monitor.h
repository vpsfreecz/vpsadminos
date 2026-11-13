/* SPDX-License-Identifier: GPL-2.0 */
#ifndef RTNL_MONITOR_H
#define RTNL_MONITOR_H
#ifndef __BPF__
#include <linux/types.h>
#endif
#define MONITOR_VERSION "1.0.0"
#define MONITOR_COVERAGE "global_blocking_wrappers_v1"
#define MONITOR_LEVELS 16
#define MONITOR_STACKS 256
#define MONITOR_STACK_DEPTH 32
#define MONITOR_STACK_WINDOW_NS 30000000000ULL
#define MONITOR_ROOTS_LIMIT 1024
#define MONITOR_ROOT_MAP_ENTRIES (MONITOR_ROOTS_LIMIT + MONITOR_LEVELS)
#define MONITOR_PENDING_LIMIT 65536

enum monitor_api { API_LOCK = 1, API_KILLABLE, API_REFCOUNT };
enum monitor_loss {
  LOSS_PENDING_FULL, LOSS_DUPLICATE, LOSS_MAP_READ, LOSS_OUTPUT,
  LOSS_STACK_CAPTURE, LOSS_STACK_OUTPUT, LOSS_COUNT
};
struct pending_call {
  __u64 entered_ns;
  __u64 leaf_cgroup_id;
  __u64 root_token;
  __u32 api;
  __u32 flags;
  __s32 stack_id;
  __u32 padding;
};
/* kind0 holds ancestor levels at id0..15; kind1 holds cgroup-ID -> token. */
struct root_key { __u64 kind; __u64 id; };
struct root_value { __u64 token; __u64 sampling_key; };
struct stack_event { __u64 pid_tgid; struct pending_call call; };
struct monitor_rodata { __u32 stacks_enabled; };
#ifndef __BPF__
_Static_assert(sizeof(struct pending_call) == 40, "pending ABI size");
_Static_assert(__builtin_offsetof(struct pending_call, stack_id) == 32, "stack ABI offset");
_Static_assert(sizeof(struct root_key) == 16, "root key ABI");
_Static_assert(sizeof(struct stack_event) == 48, "stack event ABI");
#endif
#endif
