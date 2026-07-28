{
  lib,
  version ? null,
  ...
}:
with lib;

let

  availablePatches = [
    {
      name = "bp-6.12.95-cumulative";
      filterFn = availableFor "6.12.95";
      version = 1;
      # kpatch-build groups these .ko targets into one modpost pass. Include
      # direct module dependencies so modpost sees their exported symbols.
      targets = [
        "vmlinux"
        "fs/fuse/fuse.ko"
        "net/dns_resolver/dns_resolver.ko"
        "fs/nfs/nfsv4.ko"
        "net/llc/llc.ko"
        "net/802/stp.ko"
        "net/bridge/bridge.ko"
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
        "net/ipv6/netfilter/nf_defrag_ipv6.ko"
        "net/netfilter/nf_conntrack.ko"
        "net/netfilter/ipvs/ip_vs.ko"
        "net/netfilter/nf_tables.ko"
        "net/netfilter/nfnetlink_queue.ko"
        "net/vmw_vsock/vsock.ko"
        "net/vmw_vsock/vmw_vsock_virtio_transport_common.ko"
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

  patchListForVersion = kernelVersion: map (patch: patch.name) (filterPatches kernelVersion);
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
