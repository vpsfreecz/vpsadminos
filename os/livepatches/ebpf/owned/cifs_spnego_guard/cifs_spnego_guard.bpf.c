// SPDX-License-Identifier: GPL-2.0
/*
 * cifs_spnego_guard.bpf.c - BPF LSM guard for forged cifs.spnego keys.
 *
 * The in-kernel fix rejects cifs.spnego descriptions unless they are produced
 * while CIFS is using its private spnego credential. BPF cannot compare that
 * static cred pointer directly, so this livepatch allows only the observable
 * CIFS-private thread keyring used by that credential.
 */
#include "vmlinux.h"
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_tracing.h>
#include <bpf/bpf_core_read.h>

#define EPERM 1

char LICENSE[] SEC("license") = "GPL";

static __always_inline int streq_cifs_spnego(const char *s)
{
  char buf[13];
  long len;

  if (!s)
    return 0;

  len = bpf_probe_read_kernel_str(buf, sizeof(buf), s);
  if (len != 12)
    return 0;

  return buf[0] == 'c' && buf[1] == 'i' && buf[2] == 'f'
    && buf[3] == 's' && buf[4] == '.' && buf[5] == 's'
    && buf[6] == 'p' && buf[7] == 'n' && buf[8] == 'e'
    && buf[9] == 'g' && buf[10] == 'o' && buf[11] == '\0';
}

static __always_inline int streq_keyring(const char *s)
{
  char buf[9];
  long len;

  if (!s)
    return 0;

  len = bpf_probe_read_kernel_str(buf, sizeof(buf), s);
  if (len != 8)
    return 0;

  return buf[0] == 'k' && buf[1] == 'e' && buf[2] == 'y'
    && buf[3] == 'r' && buf[4] == 'i' && buf[5] == 'n'
    && buf[6] == 'g' && buf[7] == '\0';
}

static __always_inline int streq_cifs_spnego_keyring(const char *s)
{
  char buf[14];
  long len;

  if (!s)
    return 0;

  len = bpf_probe_read_kernel_str(buf, sizeof(buf), s);
  if (len != 13)
    return 0;

  return buf[0] == '.' && buf[1] == 'c' && buf[2] == 'i'
    && buf[3] == 'f' && buf[4] == 's' && buf[5] == '_'
    && buf[6] == 's' && buf[7] == 'p' && buf[8] == 'n'
    && buf[9] == 'e' && buf[10] == 'g' && buf[11] == 'o'
    && buf[12] == '\0';
}

static __always_inline int cred_uses_cifs_spnego_keyring(const struct cred *cred)
{
  struct key *thread_keyring;
  struct key_type *keyring_type;
  const char *keyring_type_name;
  const char *description;

  if (!cred)
    return 0;

  thread_keyring = BPF_CORE_READ(cred, thread_keyring);
  if (!thread_keyring)
    return 0;

  keyring_type = BPF_CORE_READ(thread_keyring, index_key.type);
  if (!keyring_type)
    return 0;

  keyring_type_name = BPF_CORE_READ(keyring_type, name);
  if (!streq_keyring(keyring_type_name))
    return 0;

  description = BPF_CORE_READ(thread_keyring, index_key.description);
  return streq_cifs_spnego_keyring(description);
}

SEC("lsm/key_alloc")
int BPF_PROG(cifs_spnego, struct key *key, const struct cred *cred,
             unsigned long flags, int ret)
{
  struct key_type *type;
  const char *type_name;

  (void)flags;

  if (ret)
    return ret;

  type = BPF_CORE_READ(key, index_key.type);
  if (!type)
    return 0;

  type_name = BPF_CORE_READ(type, name);
  if (!streq_cifs_spnego(type_name))
    return 0;

  if (cred_uses_cifs_spnego_keyring(cred))
    return 0;

  bpf_printk("ebpf-livepatch: denied userspace cifs.spnego key allocation\n");
  return -EPERM;
}
