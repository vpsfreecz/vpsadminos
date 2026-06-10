// SPDX-License-Identifier: GPL-2.0
/*
 * nft_cve23111_guard.bpf.c - BPF LSM mitigation for CVE-2026-23111.
 *
 * CVE-2026-23111 is triggered when nf_tables aborts a transaction after a
 * verdict map with a catchall jump/goto element has been deleted. The buggy
 * abort path fails to restore the chain reference held by that catchall
 * element.
 *
 * This guard watches nf_tables netlink requests from non-initial user
 * namespaces, remembers sets that look like catchall verdict maps, and denies
 * multi-operation batches that delete those remembered sets. A standalone
 * delete is allowed because it commits rather than going through abort.
 *
 * Load this before starting containers. The guard learns from netlink requests
 * it observes and does not enumerate nf_tables state that already exists.
 */
#include "vmlinux.h"
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_tracing.h>
#include <bpf/bpf_core_read.h>
#include <bpf/bpf_endian.h>

#define EPERM 1

#define NETLINK_NETFILTER 12

#define NLMSG_HDRLEN 16
#define NLMSG_MIN_TYPE 0x10

#define NLA_HDRLEN 4
#define NLA_F_NESTED (1U << 15)
#define NLA_F_NET_BYTEORDER (1U << 14)
#define NLA_TYPE_MASK (~(NLA_F_NESTED | NLA_F_NET_BYTEORDER))

#define NFNL_SUBSYS_NFTABLES 10
#define NFNL_MSG_BATCH_BEGIN NLMSG_MIN_TYPE
#define NFNL_MSG_BATCH_END (NLMSG_MIN_TYPE + 1)

#define NFT_MSG_NEWSET 9
#define NFT_MSG_DELSET 11
#define NFT_MSG_NEWSETELEM 12
#define NFT_MSG_DESTROYSET 29

#define NFTA_SET_TABLE 1
#define NFTA_SET_NAME 2
#define NFTA_SET_FLAGS 3
#define NFTA_SET_DATA_TYPE 6

#define NFT_SET_MAP 0x8
#define NFT_DATA_VERDICT 0xffffff00U

#define NFTA_SET_ELEM_LIST_TABLE 1
#define NFTA_SET_ELEM_LIST_SET 2
#define NFTA_SET_ELEM_LIST_ELEMENTS 3

#define NFTA_SET_ELEM_DATA 2
#define NFTA_SET_ELEM_FLAGS 3
#define NFT_SET_ELEM_CATCHALL 0x2

#define NFTA_DATA_VERDICT 2

#define NFTA_VERDICT_CODE 1
#define NFTA_VERDICT_CHAIN 2
#define NFTA_VERDICT_CHAIN_ID 3

#define NFT_JUMP_U32 0xfffffffdU
#define NFT_GOTO_U32 0xfffffffcU

#define MAX_MSGS 64
#define MAX_ATTRS 48
#define MAX_ELEMS 16
#define MAX_STR_HASH_BYTES 64

#define SET_STATE_VERDICT_MAP 0x1
#define SET_STATE_CATCHALL_CHAIN 0x2
#define SET_STATE_RISKY (SET_STATE_VERDICT_MAP | SET_STATE_CATCHALL_CHAIN)

struct risky_set_key {
  __u32 netns_inum;
  __u8 family;
  __u8 pad[3];
  __u64 table_hash;
  __u64 set_hash;
};

struct nft_guard_nfgenmsg {
  __u8 nfgen_family;
  __u8 version;
  __u16 res_id;
};

struct attr_scan {
  __u64 table_hash;
  __u64 set_hash;
  __u32 flags;
  __u32 data_type;
  __u8 has_table;
  __u8 has_set;
  __u8 has_flags;
  __u8 has_data_type;
};

struct batch_scan {
  __u8 real_ops;
  __u8 saw_batch;
  __u8 risky_delete;
  __u8 unknown_delete;
  __u8 truncated_after_guarded_delete;
};

struct {
  __uint(type, BPF_MAP_TYPE_LRU_HASH);
  __uint(max_entries, 8192);
  __type(key, struct risky_set_key);
  __type(value, __u8);
} set_states SEC(".maps");

char LICENSE[] SEC("license") = "GPL";

static __always_inline __u32 align4(__u32 len)
{
  return (len + 3) & ~3U;
}

static __always_inline int current_userns_is_initial(void)
{
  struct task_struct *task = bpf_get_current_task_btf();
  const struct cred *cred;
  struct user_namespace *user_ns;
  int level;

  cred = BPF_CORE_READ(task, cred);
  if (!cred)
    return 0;

  user_ns = BPF_CORE_READ(cred, user_ns);
  if (!user_ns)
    return 0;

  level = BPF_CORE_READ(user_ns, level);
  return level == 0;
}

static __always_inline __u32 socket_netns_inum(const struct sock *sk)
{
  struct net *net_ns;

  net_ns = BPF_CORE_READ(sk, __sk_common.skc_net.net);
  if (!net_ns)
    return 0;

  return BPF_CORE_READ(net_ns, ns.inum);
}

static __always_inline int skb_read(
  const struct sk_buff *skb,
  __u32 off,
  void *dst,
  __u32 len
)
{
  void *data;
  __u32 skb_len;

  skb_len = BPF_CORE_READ(skb, len);
  if (off > skb_len || len > skb_len - off)
    return -1;

  data = BPF_CORE_READ(skb, data);
  if (!data)
    return -1;

  return bpf_probe_read_kernel(dst, len, (char *)data + off);
}

static __always_inline int read_u32_be(
  const struct sk_buff *skb,
  __u32 off,
  __u32 *value
)
{
  __u32 raw;

  if (skb_read(skb, off, &raw, sizeof(raw)) < 0)
    return -1;

  *value = bpf_ntohl(raw);
  return 0;
}

static __always_inline __u64 hash_attr_string(
  const struct sk_buff *skb,
  __u32 off,
  __u32 len
)
{
  __u64 hash = 14695981039346656037ULL;
  __u8 c = 0;
  int i;

  for (i = 0; i < MAX_STR_HASH_BYTES; i++) {
    if ((__u32)i >= len)
      break;

    if (skb_read(skb, off + i, &c, sizeof(c)) < 0)
      break;

    if (c == 0)
      break;

    hash ^= c;
    hash *= 1099511628211ULL;
  }

  return hash;
}

static __always_inline __u16 attr_type(__u16 nla_type)
{
  return nla_type & NLA_TYPE_MASK;
}

static __always_inline int parse_verdict_attr(
  const struct sk_buff *skb,
  __u32 start,
  __u32 end
)
{
  __u8 has_chain_ref = 0;
  __u8 is_jump_or_goto = 0;
  __u32 off = start;
  int i;

  for (i = 0; i < MAX_ATTRS; i++) {
    struct nlattr nla;
    __u32 payload_off, payload_len, next;
    __u16 type;
    __u32 code;

    if (off + NLA_HDRLEN > end)
      break;

    if (skb_read(skb, off, &nla, sizeof(nla)) < 0)
      break;

    if (nla.nla_len < NLA_HDRLEN || off + nla.nla_len > end)
      break;

    payload_off = off + NLA_HDRLEN;
    payload_len = nla.nla_len - NLA_HDRLEN;
    type = attr_type(nla.nla_type);

    if (type == NFTA_VERDICT_CODE) {
      if (payload_len >= sizeof(code) &&
          read_u32_be(skb, payload_off, &code) == 0 &&
          (code == NFT_JUMP_U32 || code == NFT_GOTO_U32))
        is_jump_or_goto = 1;
    } else if (type == NFTA_VERDICT_CHAIN || type == NFTA_VERDICT_CHAIN_ID) {
      has_chain_ref = 1;
    }

    next = off + align4(nla.nla_len);
    if (next <= off)
      break;
    off = next;
  }

  return is_jump_or_goto && has_chain_ref;
}

static __always_inline int parse_data_attr(
  const struct sk_buff *skb,
  __u32 start,
  __u32 end
)
{
  __u32 off = start;
  int i;

  for (i = 0; i < MAX_ATTRS; i++) {
    struct nlattr nla;
    __u32 payload_off, payload_len, next;

    if (off + NLA_HDRLEN > end)
      break;

    if (skb_read(skb, off, &nla, sizeof(nla)) < 0)
      break;

    if (nla.nla_len < NLA_HDRLEN || off + nla.nla_len > end)
      break;

    payload_off = off + NLA_HDRLEN;
    payload_len = nla.nla_len - NLA_HDRLEN;

    if (attr_type(nla.nla_type) == NFTA_DATA_VERDICT &&
        parse_verdict_attr(skb, payload_off, payload_off + payload_len))
      return 1;

    next = off + align4(nla.nla_len);
    if (next <= off)
      break;
    off = next;
  }

  return 0;
}

static __always_inline int parse_elem_attr(
  const struct sk_buff *skb,
  __u32 start,
  __u32 end
)
{
  __u8 catchall = 0;
  __u8 verdict_chain = 0;
  __u32 off = start;
  int i;

  for (i = 0; i < MAX_ATTRS; i++) {
    struct nlattr nla;
    __u32 payload_off, payload_len, next;
    __u16 type;
    __u32 flags;

    if (off + NLA_HDRLEN > end)
      break;

    if (skb_read(skb, off, &nla, sizeof(nla)) < 0)
      break;

    if (nla.nla_len < NLA_HDRLEN || off + nla.nla_len > end)
      break;

    payload_off = off + NLA_HDRLEN;
    payload_len = nla.nla_len - NLA_HDRLEN;
    type = attr_type(nla.nla_type);

    if (type == NFTA_SET_ELEM_FLAGS) {
      if (payload_len >= sizeof(flags) &&
          read_u32_be(skb, payload_off, &flags) == 0 &&
          (flags & NFT_SET_ELEM_CATCHALL))
        catchall = 1;
    } else if (type == NFTA_SET_ELEM_DATA) {
      if (parse_data_attr(skb, payload_off, payload_off + payload_len))
        verdict_chain = 1;
    }

    next = off + align4(nla.nla_len);
    if (next <= off)
      break;
    off = next;
  }

  return catchall && verdict_chain;
}

static __always_inline int parse_elements_attr(
  const struct sk_buff *skb,
  __u32 start,
  __u32 end
)
{
  __u32 off = start;
  int i;

  for (i = 0; i < MAX_ELEMS; i++) {
    struct nlattr nla;
    __u32 payload_off, payload_len, next;

    if (off + NLA_HDRLEN > end)
      break;

    if (skb_read(skb, off, &nla, sizeof(nla)) < 0)
      break;

    if (nla.nla_len < NLA_HDRLEN || off + nla.nla_len > end)
      break;

    payload_off = off + NLA_HDRLEN;
    payload_len = nla.nla_len - NLA_HDRLEN;

    if (parse_elem_attr(skb, payload_off, payload_off + payload_len))
      return 1;

    next = off + align4(nla.nla_len);
    if (next <= off)
      break;
    off = next;
  }

  return 0;
}

static __always_inline void parse_set_attrs(
  const struct sk_buff *skb,
  __u32 start,
  __u32 end,
  struct attr_scan *scan
)
{
  __u32 off = start;
  int i;

  for (i = 0; i < MAX_ATTRS; i++) {
    struct nlattr nla;
    __u32 payload_off, payload_len, next;
    __u16 type;

    if (off + NLA_HDRLEN > end)
      break;

    if (skb_read(skb, off, &nla, sizeof(nla)) < 0)
      break;

    if (nla.nla_len < NLA_HDRLEN || off + nla.nla_len > end)
      break;

    payload_off = off + NLA_HDRLEN;
    payload_len = nla.nla_len - NLA_HDRLEN;
    type = attr_type(nla.nla_type);

    if (type == NFTA_SET_TABLE) {
      scan->table_hash = hash_attr_string(skb, payload_off, payload_len);
      scan->has_table = 1;
    } else if (type == NFTA_SET_NAME) {
      scan->set_hash = hash_attr_string(skb, payload_off, payload_len);
      scan->has_set = 1;
    } else if (type == NFTA_SET_FLAGS) {
      if (payload_len >= sizeof(scan->flags) &&
          read_u32_be(skb, payload_off, &scan->flags) == 0)
        scan->has_flags = 1;
    } else if (type == NFTA_SET_DATA_TYPE) {
      if (payload_len >= sizeof(scan->data_type) &&
          read_u32_be(skb, payload_off, &scan->data_type) == 0)
        scan->has_data_type = 1;
    }

    next = off + align4(nla.nla_len);
    if (next <= off)
      break;
    off = next;
  }
}

static __always_inline int parse_newsetelem_attrs(
  const struct sk_buff *skb,
  __u32 start,
  __u32 end,
  struct attr_scan *scan
)
{
  __u8 has_risky_elem = 0;
  __u32 off = start;
  int i;

  for (i = 0; i < MAX_ATTRS; i++) {
    struct nlattr nla;
    __u32 payload_off, payload_len, next;
    __u16 type;

    if (off + NLA_HDRLEN > end)
      break;

    if (skb_read(skb, off, &nla, sizeof(nla)) < 0)
      break;

    if (nla.nla_len < NLA_HDRLEN || off + nla.nla_len > end)
      break;

    payload_off = off + NLA_HDRLEN;
    payload_len = nla.nla_len - NLA_HDRLEN;
    type = attr_type(nla.nla_type);

    if (type == NFTA_SET_ELEM_LIST_TABLE) {
      scan->table_hash = hash_attr_string(skb, payload_off, payload_len);
      scan->has_table = 1;
    } else if (type == NFTA_SET_ELEM_LIST_SET) {
      scan->set_hash = hash_attr_string(skb, payload_off, payload_len);
      scan->has_set = 1;
    } else if (type == NFTA_SET_ELEM_LIST_ELEMENTS) {
      if (parse_elements_attr(skb, payload_off, payload_off + payload_len))
        has_risky_elem = 1;
    }

    next = off + align4(nla.nla_len);
    if (next <= off)
      break;
    off = next;
  }

  return has_risky_elem;
}

static __always_inline void mark_set_state(
  __u32 netns_inum,
  __u8 family,
  __u64 table_hash,
  __u64 set_hash,
  __u8 flag
)
{
  struct risky_set_key key = {
    .netns_inum = netns_inum,
    .family = family,
    .table_hash = table_hash,
    .set_hash = set_hash,
  };
  __u8 new_state = flag;
  __u8 *state;

  state = bpf_map_lookup_elem(&set_states, &key);
  if (state)
    new_state |= *state;

  bpf_map_update_elem(&set_states, &key, &new_state, BPF_ANY);
}

static __always_inline int set_is_risky(
  __u32 netns_inum,
  __u8 family,
  __u64 table_hash,
  __u64 set_hash
)
{
  struct risky_set_key key = {
    .netns_inum = netns_inum,
    .family = family,
    .table_hash = table_hash,
    .set_hash = set_hash,
  };
  __u8 *state;

  state = bpf_map_lookup_elem(&set_states, &key);
  return state && ((*state & SET_STATE_RISKY) == SET_STATE_RISKY);
}

static __always_inline void handle_nft_msg(
  const struct sk_buff *skb,
  __u32 attr_start,
  __u32 msg_end,
  __u8 family,
  __u8 op,
  __u32 netns_inum,
  struct batch_scan *batch
)
{
  struct attr_scan scan = { };

  if (batch->real_ops < 255)
    batch->real_ops++;

  if (op == NFT_MSG_NEWSET) {
    parse_set_attrs(skb, attr_start, msg_end, &scan);

    if (scan.has_table && scan.has_set && scan.has_flags &&
        scan.has_data_type && (scan.flags & NFT_SET_MAP) &&
        scan.data_type == NFT_DATA_VERDICT) {
      mark_set_state(
        netns_inum,
        family,
        scan.table_hash,
        scan.set_hash,
        SET_STATE_VERDICT_MAP
      );
    }

    return;
  }

  if (op == NFT_MSG_NEWSETELEM) {
    if (parse_newsetelem_attrs(skb, attr_start, msg_end, &scan) &&
        scan.has_table && scan.has_set) {
      mark_set_state(
        netns_inum,
        family,
        scan.table_hash,
        scan.set_hash,
        SET_STATE_CATCHALL_CHAIN
      );
    }

    return;
  }

  if (op == NFT_MSG_DELSET || op == NFT_MSG_DESTROYSET) {
    parse_set_attrs(skb, attr_start, msg_end, &scan);

    if (!scan.has_table || !scan.has_set) {
      batch->unknown_delete = 1;
      return;
    }

    if (set_is_risky(netns_inum, family, scan.table_hash, scan.set_hash))
      batch->risky_delete = 1;
  }
}

static __always_inline int scan_nftables_payload(
  const struct sk_buff *skb,
  __u32 len,
  __u32 netns_inum,
  struct batch_scan *batch
)
{
  __u32 off = 0;
  __u8 saw_batch_begin = 0;
  int i;

  for (i = 0; i < MAX_MSGS; i++) {
    struct nlmsghdr nlh;
    struct nft_guard_nfgenmsg nfmsg;
    __u32 msg_end, next;
    __u16 subsys, op;
    __u8 family;

    if (off + NLMSG_HDRLEN > len)
      break;

    if (skb_read(skb, off, &nlh, sizeof(nlh)) < 0)
      break;

    if (nlh.nlmsg_len < NLMSG_HDRLEN || off + nlh.nlmsg_len > len) {
      if (batch->risky_delete || batch->unknown_delete)
        batch->truncated_after_guarded_delete = 1;
      break;
    }

    msg_end = off + nlh.nlmsg_len;
    op = nlh.nlmsg_type & 0x00ff;
    subsys = (nlh.nlmsg_type & 0xff00) >> 8;

    if (nlh.nlmsg_type == NFNL_MSG_BATCH_BEGIN) {
      saw_batch_begin = 1;
      batch->saw_batch = 1;
      next = off + align4(nlh.nlmsg_len);
      if (next <= off)
        break;
      off = next;
      continue;
    }

    if (nlh.nlmsg_type == NFNL_MSG_BATCH_END)
      break;

    if (saw_batch_begin && subsys != NFNL_SUBSYS_NFTABLES) {
      if (batch->real_ops < 255)
        batch->real_ops++;
      next = off + align4(nlh.nlmsg_len);
      if (next <= off)
        break;
      off = next;
      continue;
    }

    if (subsys == NFNL_SUBSYS_NFTABLES &&
        nlh.nlmsg_len >= NLMSG_HDRLEN + sizeof(nfmsg) &&
        skb_read(skb, off + NLMSG_HDRLEN, &nfmsg, sizeof(nfmsg)) == 0) {
      family = nfmsg.nfgen_family;
      handle_nft_msg(
        skb,
        off + NLMSG_HDRLEN + sizeof(nfmsg),
        msg_end,
        family,
        op,
        netns_inum,
        batch
      );
    }

    next = off + align4(nlh.nlmsg_len);
    if (next <= off)
      break;
    off = next;
  }

  return 0;
}

SEC("lsm/netlink_send")
int BPF_PROG(nft23111_guard, struct sock *sk, struct sk_buff *skb, int ret)
{
  struct batch_scan batch = { };
  __u32 netns_inum, skb_len;
  __u16 protocol;

  if (ret)
    return ret;

  if (current_userns_is_initial())
    return 0;

  protocol = BPF_CORE_READ(sk, sk_protocol);
  if (protocol != NETLINK_NETFILTER)
    return 0;

  netns_inum = socket_netns_inum(sk);
  if (netns_inum == 0)
    return 0;

  skb_len = BPF_CORE_READ(skb, len);
  scan_nftables_payload(skb, skb_len, netns_inum, &batch);

  if (batch.saw_batch && (batch.risky_delete || batch.unknown_delete) &&
      (batch.real_ops > 1 || batch.truncated_after_guarded_delete)) {
    bpf_printk("ebpf-livepatch: denied risky nf_tables set delete batch\n");
    return -EPERM;
  }

  return 0;
}
