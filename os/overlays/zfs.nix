self: super:
{
  zfs = super.zfsUnstable.overrideAttrs (oldAttrs: rec {
    name = "zfs-${version}";
    version = "2018-05-14.vpsfree";
    src = super.fetchFromGitHub {
      owner = "vpsfreecz";
      repo = "zfs";
      rev = "7978e2638a0e05567044a09c979d1cce4916c412";
      sha256 = "1wp7nd2i9jnig6cmlxqllf7bnlrw9sknqbdfgvym42hllmm6p2k2";
    };
  });
}
