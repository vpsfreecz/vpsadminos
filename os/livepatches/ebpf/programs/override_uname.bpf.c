// SPDX-License-Identifier: GPL-2.0
/*
 * override_uname.bpf.c - eBPF livepatch: override uname syscall output.
 *
 * Uses fentry/fexit on __x64_sys_newuname (x86_64 syscall entry wrapper).
 * __do_sys_newuname is notrace, so we target the traceable wrapper.
 *
 * BPF trampoline links (fentry/fexit) support pinning for persistence.
 */
#include "vmlinux.h"
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_tracing.h>
#include <bpf/bpf_core_read.h>

char LICENSE[] SEC("license") = "GPL";

struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 256);
    __type(key, __u32);
    __type(value, __u64);
} uname_buf_map SEC(".maps");

SEC("fentry/__x64_sys_newuname")
int BPF_PROG(uname_fentry, struct pt_regs *regs)
{
    __u32 tid = bpf_get_current_pid_tgid();
    __u64 buf_ptr;
    int err;

    /* regs->di = first syscall argument (the userspace buffer) */
    err = bpf_probe_read_kernel(&buf_ptr, sizeof(buf_ptr), &regs->di);
    if (err || !buf_ptr)
        return 0;

    bpf_map_update_elem(&uname_buf_map, &tid, &buf_ptr, BPF_ANY);
    return 0;
}

SEC("fexit/__x64_sys_newuname")
int BPF_PROG(uname_fexit, struct pt_regs *regs, long ret)
{
    __u32 tid = bpf_get_current_pid_tgid();
    __u64 *ptrp;
    struct new_utsname *buf;

    if (ret != 0)
        goto cleanup;

    ptrp = bpf_map_lookup_elem(&uname_buf_map, &tid);
    if (!ptrp)
        goto cleanup;

    buf = (struct new_utsname *)(unsigned long)*ptrp;
    if (!buf)
        goto cleanup;

    bpf_probe_write_user(&buf->sysname,    "vpsAdminOS", 11);
    bpf_probe_write_user(&buf->nodename,   "ebpf-patched", 13);
    bpf_probe_write_user(&buf->release,    "6.6.6-ebpf", 11);
    bpf_probe_write_user(&buf->version,    "#1-ebpf-poc", 12);
    bpf_probe_write_user(&buf->machine,    "x86_64", 7);
    bpf_probe_write_user(&buf->domainname, "(none)", 7);

cleanup:
    bpf_map_delete_elem(&uname_buf_map, &tid);
    return 0;
}
