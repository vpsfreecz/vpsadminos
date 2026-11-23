{ lib }:
{
  dateAdded = "2026-09-08";
  rev = "9ccd5d6597a6ddbe5b44fb885ddf96e4dbc332dd";
  sha256 = "sha256-pkqWjsBfn3twbVFXP2Uk8FWvj8BJk9kTNCtSlyHZrCo=";
  zfs = {
    rev = "481845fca6ae3f61ca2262c1a5693a58ae364650";
    sha256 = "sha256-/zeZH5EJYa0zaNcbMUoeHp6UnHNAMUrjgok/VgWI88A=";
    patches = [ ../../zfs/zfs235-free-account.patch ];
  };
}
