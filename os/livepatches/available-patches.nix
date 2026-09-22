{
  lib,
  version ? null,
  ...
}:
with lib;

let

  availablePatches = [
    {
      name = "bp-6.12.95-production";
      buildPatches = [
        "bp-6.12.95-production"
        "bp-6.12.95-uname"
      ];
      filterFn = availableFor "6.12.95";
      version = 7;
      targets = [
        "vmlinux"
        "fs/fuse/fuse.ko"
        "net/dns_resolver/dns_resolver.ko"
        "fs/nfs/nfsv4.ko"
        "net/llc/llc.ko"
        "net/802/stp.ko"
        "net/bridge/bridge.ko"
        "net/bridge/br_netfilter.ko"
        "net/netfilter/nfnetlink.ko"
        "net/netfilter/ipset/ip_set.ko"
        "net/netfilter/ipset/ip_set_hash_ip.ko"
        "net/netfilter/ipset/ip_set_hash_ipmac.ko"
        "net/netfilter/ipset/ip_set_hash_ipmark.ko"
        "net/netfilter/ipset/ip_set_hash_ipport.ko"
        "net/netfilter/ipset/ip_set_hash_ipportip.ko"
        "net/netfilter/ipset/ip_set_hash_ipportnet.ko"
        "net/netfilter/ipset/ip_set_hash_mac.ko"
        "net/netfilter/ipset/ip_set_hash_net.ko"
        "net/netfilter/ipset/ip_set_hash_netiface.ko"
        "net/netfilter/ipset/ip_set_hash_netnet.ko"
        "net/netfilter/ipset/ip_set_hash_netport.ko"
        "net/netfilter/ipset/ip_set_hash_netportnet.ko"
        "lib/libcrc32c.ko"
        "net/ipv4/netfilter/nf_defrag_ipv4.ko"
        "net/ipv4/inet_diag.ko"
        "net/ipv6/netfilter/nf_defrag_ipv6.ko"
        "net/netfilter/nf_conntrack.ko"
        "net/netfilter/nf_nat.ko"
        "net/netfilter/nf_conntrack_sip.ko"
        "net/netfilter/nf_nat_sip.ko"
        "net/netfilter/ipvs/ip_vs.ko"
        "net/netfilter/nf_tables.ko"
        "net/netfilter/nfnetlink_queue.ko"
        "drivers/net/slip/slhc.ko"
        "drivers/net/ppp/ppp_generic.ko"
        "net/ipv4/udp_tunnel.ko"
        "net/ipv6/ip6_udp_tunnel.ko"
        "drivers/net/vxlan/vxlan.ko"
        "net/packet/af_packet.ko"
        "net/sctp/sctp.ko"
        "net/sctp/sctp_diag.ko"
        "fs/ceph/ceph.ko"
        "net/ceph/libceph.ko"
        "crypto/sha1_generic.ko"
        "drivers/base/firmware_loader/firmware_class.ko"
        "drivers/crypto/ccp/ccp.ko"
        "virt/lib/irqbypass.ko"
        "arch/x86/kvm/kvm.ko"
        "arch/x86/kvm/kvm-intel.ko"
        "arch/x86/kvm/kvm-amd.ko"
        "net/vmw_vsock/vsock.ko"
        "net/vmw_vsock/vmw_vsock_virtio_transport_common.ko"
        # Extended for the v7 payload (agent0, 2026-09-22): every module below
        # carries changed objects from the a2384967..fbd32d7e payload and is
        # =m in the boot config np082gl8; the v5/v6-era 52-entry list did not
        # include them (kpatch-build's explicit -t list replaces the default
        # "vmlinux modules" set, so omissions would silently drop changes).
        "fs/nfsd/nfsd.ko"
        "drivers/net/tun.ko"
        "drivers/net/slip/slip.ko"
        "fs/xfs/xfs.ko"
        "fs/ext4/ext4.ko"
        "fs/ocfs2/ocfs2.ko"
        "net/dccp/dccp.ko"
        "net/smc/smc.ko"
        "net/openvswitch/openvswitch.ko"
        "drivers/nvme/target/nvmet.ko"
        "drivers/nvme/target/nvmet-fc.ko"
        "drivers/nvme/target/nvmet-tcp.ko"
        "drivers/hid/hid-ft260.ko"
        "drivers/hid/hid-uclogic.ko"
        "drivers/hid/usbhid/usbhid.ko"
        "drivers/i3c/i3c.ko"
        "drivers/mfd/sm501.ko"
        "drivers/char/ipmi/ipmb_dev_int.ko"
        "net/ieee802154/6lowpan/ieee802154_6lowpan.ko"
        "net/6lowpan/6lowpan.ko"
        "net/ipv4/ip_tunnel.ko"
        "net/ipv6/sit.ko"
        "net/ipv6/ip6_gre.ko"
        "net/sunrpc/auth_gss/auth_rpcgss.ko"
        "net/sunrpc/auth_gss/rpcsec_gss_krb5.ko"
      ];
    }
    {
      name = "bp-6.12.48-6.12.89-cumulative";
      filterFn = availableForRange "6.12.48" "6.12.89";
      version = 1;
    }
    # The uname patch is the canonical livepatch example.
    # It changes init_uts_ns.name.release to "<kernelVer>.<patchVer>"
    # so that `uname -r` shows the livepatch is active.
    # Uncomment to enable:
    # {
    #   name = "uname";
    #   filterFn = availableForAllKernels;
    # }
  ];

  availableForAllKernels = kernelVersion: true;
  availableFor = compatVersion: kernelVersion: kernelVersion == compatVersion;
  availableSince = verLow: kernelVersion: (versionAtLeast kernelVersion verLow);
  availableForRange =
    verLow: verHigh: kernelVersion:
    (versionAtLeast kernelVersion verLow && versionUpTo kernelVersion verHigh);
  versionUpTo = v1: v2: builtins.compareVersions v1 v2 < 1;

  getPatchVersion = patch: if (hasAttr "version" patch) then patch.version else 1;
  filterPatches = kernelVersion: filter (patch: patch.filterFn kernelVersion) availablePatches;
  filterPatchesVersions = kernelVersion: map getPatchVersion (filterPatches kernelVersion);
  filterPatchesVersionsSum =
    kernelVersion: foldl (x: y: x + y) 0 (filterPatchesVersions kernelVersion);

  patchListForVersion =
    kernelVersion:
    concatMap (patch: patch.buildPatches or [ patch.name ]) (filterPatches kernelVersion);
  patchTargetsForVersion =
    kernelVersion: unique (concatMap (patch: patch.targets or [ ]) (filterPatches kernelVersion));
in
{
  getPatchVersion = getPatchVersion;
  patchList = patchListForVersion version;
  patchTargets = patchTargetsForVersion version;
  patchVersion = filterPatchesVersionsSum version;
  filteredPatches = filterPatches version;
  allPatches = availablePatches;
}
