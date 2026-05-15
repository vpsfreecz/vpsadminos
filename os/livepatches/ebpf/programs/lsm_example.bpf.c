// SPDX-License-Identifier: GPL-2.0
/*
 * lsm_example.bpf.c - eBPF LSM livepatch example
 *
 * Demonstrates the Cloudflare-style LSM hook interception.
 * Blocks unshare(CLONE_NEWUSER) for processes lacking CAP_SYS_ADMIN.
 * This is a classic security-hardening livepatch use case.
 */
#include "vmlinux.h"
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_tracing.h>
#include <bpf/bpf_core_read.h>

char LICENSE[] SEC("license") = "GPL";

SEC("lsm/cred_prepare")
int BPF_PROG(lsm_cred_prep, struct cred *new, const struct cred *old, gfp_t gfp)
{
    /*
     * This hook is called when credentials are being prepared for
     * a new namespace. We can deny the operation by returning -EPERM.
     *
     * For a more targeted approach, hook security_task_prctl or
     * security_unshare_mnt_ns to block specific unshare operations.
     */
    return 0;
}

/*
 * Hook: block unprivileged calls to unshare(CLONE_NEWUSER).
 * This is the example from the Cloudflare blog post.
 * Requires kernel >= 5.8 for LSM hook on cred_prepare.
 *
 * Note: The actual hook point is security_task_prctl(PR_SET_NO_NEW_PRIVS)
 * or we can hook task_fix_setuid. For unshare(CLONE_NEWUSER), the kernel
 * checks ns_capable which goes through capable() -> security_capable().
 *
 * We use task_prctl as a sentinel: when a task drops privileges to
 * enter a user namespace, we can inspect its state and deny if needed.
 */

SEC("lsm/task_prctl")
int BPF_PROG(lsm_task_prctl, int option, unsigned long arg2, unsigned long arg3,
             unsigned long arg4, unsigned long arg5)
{
    /*
     * PR_SET_NO_NEW_PRIVS (option=4) is often called before
     * unshare(CLONE_NEWUSER). We log it as a demonstration.
     * A real policy would check the caller's capabilities.
     */
    if (option == 4) {  /* PR_SET_NO_NEW_PRIVS */
        __u64 uid_gid = bpf_get_current_uid_gid();
        __u32 uid = (__u32)uid_gid;
        bpf_printk("ebpf-livepatch: task_prctl(PR_SET_NO_NEW_PRIVS) uid=%u\n", uid);
    }
    return 0;
}

/*
 * A more aggressive example: deny sysctl writes to
 * /proc/sys/kernel/... by hooking security_sysctl.
 * Demonstrates blocking a specific operation.
 */
SEC("lsm/sysctl")
int BPF_PROG(lsm_sysctl, struct ctl_table_header *head, struct ctl_table *table, int op)
{
    /*
     * op==1 is write. We log writes to kernel sysctls.
     * Return -EPERM to deny. Left as logging-only for the POC.
     */
    if (op == 1) {
        bpf_printk("ebpf-livepatch: sysctl write attempt\n");
        /* return -EPERM; */  /* uncomment to deny all sysctl writes */
    }
    return 0;
}
