self: super:
{
  mbuffer = super.mbuffer.overrideAttrs (oldAttrs: rec {
    version = "R20210829";

    src = super.fetchFromGitHub {
      owner = "vpsfreecz";
      repo = "mbuffer";
      rev = "6410b42c0d864dee0afe8bef59113c07e68093f8";
      sha256 = "sha256:1py5hvn83jirdif0gid9sfh5a0zgjf0w8nwi7nzzp6kq0r83m4vn";
    };

    nativeBuildInputs = [ super.which ];
  });
}
