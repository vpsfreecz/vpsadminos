// SPDX-License-Identifier: GPL-2.0
/*
 * override_uname.bpf.c - eBPF livepatch: override uname syscall output.
 *
 * Attaches a kprobe/kretprobe pair on __do_sys_newuname.
 * On return, overwrites the userspace buffer with spoofed utsname fields.
 */
#include "vmlinux.h"
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_tracing.h>
#include <bpf/bpf_core_read.h>

char LICENSE[] SEC("license") = "GPL";

/* Keyed by tid, stores the userspace buffer pointer passed to uname. */
struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 256);
    __type(key, __u32);
    __type(value, __u64);
} uname_buf_map SEC(".maps");

SEC("kprobe/__do_sys_newuname")
int BPF_KPROBE(kprobe__do_sys_newuname, struct new_utsname __user *buf)
{
    __u32 tid = bpf_get_current_pid_tgid() & 0xFFFFFFFF;
    __u64 ptr = (__u64)buf;

    if (!buf)
        return 0;

    bpf_map_update_elem(&uname_buf_map, &tid, &ptr, BPF_ANY);
    return 0;
}

SEC("kretprobe/__do_sys_newuname")
int BPF_KRETPROBE(kretprobe__do_sys_newuname, int ret)
{
    __u32 tid = bpf_get_current_pid_tgid() & 0xFFFFFFFF;
    __u64 *ptrp;
    struct new_utsname *buf;

    if (ret != 0)
        goto cleanup;

    ptrp = bpf_map_lookup_elem(&uname_buf_map, &tid);
    if (!ptrp)
        goto cleanup;

    buf = (struct new_utsname *)*ptrp;
    if (!buf)
        goto cleanup;

    /*
     * Overwrite the userspace buffer with spoofed values.
     * Use bpf_probe_write_user to write to userspace memory.
     */
    bpf_probe_write_user(&buf->sysname,  "vpsAdminOS",  sizeof("vpsAdminOS"));
    bpf_probe_write_user(&buf->nodename, "ebpf-patched", sizeof("ebpf-patched"));
    bpf_probe_write_user(&buf->release,  "6.6.6-ebpf-livepatch", sizeof("6.6.6-ebpf-livepatch"));
    bpf_probe_write_user(&buf->version,  "#1-ebpf-livepatch SMP PREEMPT_DYNAMIC", sizeof("#1-ebpf-livepatch SMP PREEMPT_DYNAMIC"));
    bpf_probe_write_user(&buf->machine,  "x86_64", sizeof("x86_64"));
    bpf_probe_write_user(&buf->domainname, "(none)", sizeof("(none)"));

    bpf_printk("ebpf-livepatch: overrode uname for tid %u\n", tid);

cleanup:
    bpf_map_delete_elem(&uname_buf_map, &tid);
    return 0;
}
