// SPDX-License-Identifier: GPL-2.0
/*
 * ptrace_mm_guard.bpf.c - BPF LSM guard for mm-less ptrace targets.
 *
 * The upstream kernel fix caches dumpability before task->mm is cleared.
 * BPF cannot add a task_struct field, so this mitigation fails closed for
 * tasks whose mm is already NULL unless the caller has CAP_SYS_PTRACE in the
 * initial user namespace.
 */
#include "vmlinux.h"
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_tracing.h>
#include <bpf/bpf_core_read.h>

#define EPERM 1
#define CAP_SYS_PTRACE 19
#define CAP_SYS_PTRACE_MASK (1ULL << CAP_SYS_PTRACE)

char LICENSE[] SEC("license") = "GPL";

static __always_inline int current_has_init_ns_cap_sys_ptrace(void)
{
  struct task_struct *task = bpf_get_current_task_btf();
  const struct cred *cred;
  struct user_namespace *user_ns;
  __u64 cap_effective;
  int level;

  cred = BPF_CORE_READ(task, cred);
  if (!cred)
    return 0;

  user_ns = BPF_CORE_READ(cred, user_ns);
  if (!user_ns)
    return 0;

  /*
   * ns_capable(&init_user_ns, CAP_SYS_PTRACE) only succeeds for creds in
   * init_user_ns. For user namespaces, level 0 is init_user_ns.
   */
  level = BPF_CORE_READ(user_ns, level);
  if (level != 0)
    return 0;

  cap_effective = BPF_CORE_READ(cred, cap_effective.val);
  return (cap_effective & CAP_SYS_PTRACE_MASK) != 0;
}

SEC("lsm/ptrace_access_check")
int BPF_PROG(ptrace_mm_guard, struct task_struct *child, unsigned int mode, int ret)
{
  struct mm_struct *mm;

  if (ret)
    return ret;

  mm = BPF_CORE_READ(child, mm);
  if (mm)
    return 0;

  if (current_has_init_ns_cap_sys_ptrace())
    return 0;

  return -EPERM;
}
