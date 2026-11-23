{ lib }:
{
  dateAdded = "2026-11-12";
  rev = "764acbb0ca8c4b60ee5b98f89406b152e992b1d6";
  sha256 = "sha256-50USYq3vBk2bZZAjLplWXmqa3qL/UOm6sGx3v4+xRhw=";
  zfs = {
    rev = "481845fca6ae3f61ca2262c1a5693a58ae364650";
    sha256 = "sha256-/zeZH5EJYa0zaNcbMUoeHp6UnHNAMUrjgok/VgWI88A=";
    patches = [ ../../zfs/zfs235-free-account.patch ];
  };
}
