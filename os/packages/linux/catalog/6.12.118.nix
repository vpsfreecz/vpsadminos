{ lib }:
{
  dateAdded = "2026-11-17";
  rev = "3bba27296b6f4f4a2b1568d65cea6037368f229b";
  sha256 = "sha256-tXgl0RdF3YigscvXI/tD5QHbujUV+6bVW+KIyESG93U=";
  zfs = {
    rev = "481845fca6ae3f61ca2262c1a5693a58ae364650";
    sha256 = "sha256-/zeZH5EJYa0zaNcbMUoeHp6UnHNAMUrjgok/VgWI88A=";
    patches = [ ../../zfs/zfs235-free-account.patch ];
  };
}
