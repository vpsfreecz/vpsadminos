{ lib }:
with lib.kernel;
{
  dateAdded = "2026-10-12";
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
}
