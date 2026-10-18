{ lib }:
with lib.kernel;
{
  stableKernelVersion = "6.12.113";
  unstableKernelVersion = "6.18.49";

  kernels = {
    "6.18.49" = {
      rev = "364b298b8e8cf79c2d06f5e0eb38045cd70cd197";
      # Linux uses fetchurl: hash archive bytes, not the unpacked source tree.
      sha256 = "sha256-Rr0ql/tQzXVuI1ylT6M5ozADPopMhhSCrTy74RUtt6w=";
      structuredExtraConfig = {
        DAMON = yes;
        DAMON_VADDR = yes;
        DAMON_PADDR = yes;
        DAMON_SYSFS = yes;
        DAMON_RECLAIM = yes;
        PSI = no;
        SCHED_CLASS_EXT = no;
        SCHED_PROXY_EXEC = yes;
        TRACING_NS = yes;
      };
      zfs = {
        rev = "60536e063336cb5daaec84637297f738a399c44c";
        sha256 = "sha256-hZobxKP9MIVOFRVueXG7oTGTiPJVIp9d+J3HRNJKUsw=";
      };
    };
    "6.18.44" = {
      rev = "15f0cb69214054627f1d2b1c0d14556c15a1ace3";
      sha256 = "sha256-/dXTySrZXulvADPPDzfV7H9xIFvyDboLTF6SLI6OsE4=";
      structuredExtraConfig = {
        DAMON = yes;
        DAMON_VADDR = yes;
        DAMON_PADDR = yes;
        DAMON_SYSFS = yes;
        DAMON_RECLAIM = yes;
        PSI = no;
        SCHED_CLASS_EXT = no;
        SCHED_PROXY_EXEC = yes;
        TRACING_NS = yes;
      };
      zfs = {
        rev = "b2ade5816c3a16f779616c6d25710f7f2bca7ce9";
        sha256 = "sha256-OHzDCuQ9fP3qKPhA3QysBOwqzWiFUir6BcHv2hIONPg=";
      };
    };
    "6.12.113" = {
      rev = "50e2a54f0d04b1ad2885374637b3840be37a1344";
      sha256 = "sha256-l2klScrVmb3GujXlajIGMUdrRik6Tm5FMHl7Gip82bs=";
      zfs = {
        rev = "481845fca6ae3f61ca2262c1a5693a58ae364650";
        sha256 = "sha256-/zeZH5EJYa0zaNcbMUoeHp6UnHNAMUrjgok/VgWI88A=";
        patches = [ ../zfs/zfs235-free-account.patch ];
      };
    };
    # Native 6.12.110 candidate with batched perf moves and bounded livepatch scans.
    # The archive hash was realized from the guarded-published 1e823162 ref.
    # features.livepatch = true keeps the single-series 6.12.95 identity
    # contract: the boot kernel retains a content-derived GNU SHA1 build ID.
    "6.12.110" = {
      rev = "1e8231622eee447c960f75840340702a12675322";
      sha256 = "sha256-aKj3F7leLjraNREhxE85CBb6pSsVHkFmXFeg47+LtNc=";
      features.livepatch = true;
      postConfigPatches = [ ./native-nmi-sched.patch ];
      zfs = {
        rev = "481845fca6ae3f61ca2262c1a5693a58ae364650";
        sha256 = "sha256-/zeZH5EJYa0zaNcbMUoeHp6UnHNAMUrjgok/VgWI88A=";
        patches = [ ../zfs/zfs235-free-account.patch ];
      };
    };
    "6.12.109" = {
      rev = "9ccd5d6597a6ddbe5b44fb885ddf96e4dbc332dd";
      sha256 = "sha256-pkqWjsBfn3twbVFXP2Uk8FWvj8BJk9kTNCtSlyHZrCo=";
      zfs = {
        rev = "481845fca6ae3f61ca2262c1a5693a58ae364650";
        sha256 = "sha256-/zeZH5EJYa0zaNcbMUoeHp6UnHNAMUrjgok/VgWI88A=";
        patches = [ ../zfs/zfs235-free-account.patch ];
      };
    };
    "6.12.95" = {
      rev = "a2384967b90f24d2470c9eb15f0e66d938df7e08";
      sha256 = "sha256-QlwV4uFeX7ZbWHMuU14rFXswmpqpb1hdVmYUAGOWRh8=";
      features.livepatch = true;
      zfs = {
        rev = "481845fca6ae3f61ca2262c1a5693a58ae364650";
        sha256 = "sha256-/zeZH5EJYa0zaNcbMUoeHp6UnHNAMUrjgok/VgWI88A=";
      };
    };
    "6.12.48" = {
      rev = "5bbd15d9e42bca0ca4a8d102f5ea95cc71803e44";
      sha256 = "sha256-sJThPPzpW2gZinao9dLBpFokxwpsm3U4QxHvNk0S+GA=";
      zfs = {
        rev = "e0156ef58e8a113524efa45553e0321bf8c0f124";
        sha256 = "sha256-4Y73rsSguirDTHZHZATcMGeN3vWwlqEEWZOnBXJDNu8=";
      };
    };
  };
}
