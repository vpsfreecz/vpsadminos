self: super:
{
  lxc = super.lxc.overrideAttrs (oldAttrs: rec {
    src = super.fetchFromGitHub {
      owner = "vpsfreecz";
      repo = "lxc";
      rev = "29d65251472dd02a79688e2bd88939ed334df444";
      sha256 = "1b2wfqi0kfpws8icp8kq5xwbd3sna8ixnxnm7whc52pq7rsz7b2b";
    };
  });
}
