{
  pkgs,
  candidateModule,
  bootKernel,
}:
let
  python = pkgs.python3.withPackages (ps: [
    ps.pyelftools
    ps.capstone
  ]);
  testSource = pkgs.lib.cleanSourceWith {
    src = ./.;
    filter =
      path: type:
      type == "directory"
      || builtins.elem (builtins.baseNameOf path) [
        "probe-sites.py"
        "test_probe_sites.py"
      ]
      || pkgs.lib.hasPrefix (toString ./. + "/probe-sites-tests/") path;
  };
  resolver = pkgs.writeShellApplication {
    name = "livepatch-probe-sites";
    runtimeInputs = [ python ];
    text = ''
      exec python ${./probe-sites.py} "$@"
    '';
  };
  siteChecks =
    pkgs.runCommand "livepatch-probe-site-checks"
      {
        nativeBuildInputs = [
          python
          pkgs.stdenv.cc
          pkgs.binutils
        ];
      }
      ''
        export PYTHONDONTWRITEBYTECODE=1
        python ${testSource}/test_probe_sites.py
        touch "$out"
      '';
  candidateSites =
    pkgs.runCommand "livepatch-candidate-sites"
      {
        nativeBuildInputs = [
          resolver
          pkgs.xz
          pkgs.zstd
          pkgs.gzip
        ];
      }
      ''
        # Only the archive-restored boot outputs are dependencies here. Do not
        # recreate the original nondeterministic kernel to inspect its callee.
        mapfile -t fuse_modules < <(find ${bootKernel}/lib/modules/6.12.95 -type f \
          -path '*/fs/fuse/fuse.ko*')
        test "''${#fuse_modules[@]}" -eq 1
        case "''${fuse_modules[0]}" in
          *.ko) cp "''${fuse_modules[0]}" fuse.ko ;;
          *.ko.xz) xz -dc "''${fuse_modules[0]}" > fuse.ko ;;
          *.ko.zst) zstd -dc "''${fuse_modules[0]}" > fuse.ko ;;
          *.ko.gz) gzip -dc "''${fuse_modules[0]}" > fuse.ko ;;
          *) echo 'unsupported original FUSE module compression' >&2; exit 1 ;;
        esac
        mkdir -p "$out"
        livepatch-probe-sites \
          --module ${candidateModule} \
          --sha256 "$(sha256sum ${candidateModule} | cut -d ' ' -f 1)" \
          --fuse-module fuse.ko \
          --sdk-vmlinux ${bootKernel.dev}/vmlinux \
          --output "$out/sites.json"
      '';
in
{
  inherit resolver siteChecks candidateSites;
}
