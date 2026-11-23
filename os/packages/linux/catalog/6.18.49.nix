{ lib }:
with lib.kernel;
{
  dateAdded = "2026-10-12";
  rev = "a770f5086fc500ca258852aea1cb3e209a342d2b";
  # Linux uses fetchurl: hash archive bytes, not the unpacked source tree.
  sha256 = "sha256-YJVRl+2+x+arnS3vzteI+t8LRUKAKDlONCrw9bbmZK0=";
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
}
