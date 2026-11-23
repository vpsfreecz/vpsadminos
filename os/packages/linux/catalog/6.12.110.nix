# Native 6.12.110 candidate with batched perf moves and bounded livepatch scans.
# The archive hash was realized from the guarded-published 1e823162 ref.
# features.livepatch = true keeps the single-series 6.12.95 identity
# contract: the boot kernel retains a content-derived GNU SHA1 build ID.
{ lib }:
{
  dateAdded = "2026-10-13";
  rev = "1e8231622eee447c960f75840340702a12675322";
  sha256 = "sha256-aKj3F7leLjraNREhxE85CBb6pSsVHkFmXFeg47+LtNc=";
  features.livepatch = true;
  postConfigPatches = [ ../native-nmi-sched.patch ];
  zfs = {
    rev = "481845fca6ae3f61ca2262c1a5693a58ae364650";
    sha256 = "sha256-/zeZH5EJYa0zaNcbMUoeHp6UnHNAMUrjgok/VgWI88A=";
    patches = [ ../../zfs/zfs235-free-account.patch ];
  };
}
