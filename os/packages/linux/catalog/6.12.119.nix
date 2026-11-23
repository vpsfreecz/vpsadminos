{ lib }:
{
  dateAdded = "2026-11-24";
  rev = "36574eefad15c11d26ad7adb0b8e15e6bcfe2ec5";
  sha256 = "sha256-waoWJ4veFoZdrAD96XqP8Ff15Vgv+JOJAxkUm2lDSZc=";
  zfs = {
    rev = "481845fca6ae3f61ca2262c1a5693a58ae364650";
    sha256 = "sha256-/zeZH5EJYa0zaNcbMUoeHp6UnHNAMUrjgok/VgWI88A=";
    patches = [ ../../zfs/zfs235-free-account.patch ];
  };
}
