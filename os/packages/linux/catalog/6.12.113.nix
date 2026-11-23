{ lib }:
{
  dateAdded = "2026-10-17";
  rev = "1dfea587406b7dd79973831d1677fb2418e5e9aa";
  sha256 = "sha256-IvyBosmZkpWxAK4Bz0sQ+RBwUQZwN+GtBxwjBY1lAdQ=";
  zfs = {
    rev = "481845fca6ae3f61ca2262c1a5693a58ae364650";
    sha256 = "sha256-/zeZH5EJYa0zaNcbMUoeHp6UnHNAMUrjgok/VgWI88A=";
    patches = [ ../../zfs/zfs235-free-account.patch ];
  };
}
