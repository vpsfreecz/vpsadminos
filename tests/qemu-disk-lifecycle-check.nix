{ pkgs, makeSystem }:
let
  inherit (pkgs) lib;
  sourceImage = pkgs.writeText "disk-source.img" "source contents";
  mkPreparation =
    disks:
    let
      machine = makeSystem {
        modules = [
          {
            system.stateVersion = "26.05";
            boot.qemu = {
              enable = true;
              stateDir = ".";
              inherit disks;
            };
          }
        ];
      };
      parts = lib.splitString "\nexec " machine.config.system.build.runvmScript.text;
    in
    assert builtins.length parts == 2;
    # Only execute disk preparation. Discard the unused kernel/QEMU references
    # carried by the complete launcher; sourceImage is an explicit input below.
    pkgs.writeShellScript "prepare-qemu-disks" (
      builtins.unsafeDiscardStringContext (builtins.head parts)
    );
  prepare = mkPreparation [
    {
      device = "data.img";
      type = "file";
      create = true;
      size = "1K";
    }
    {
      device = "scratch.img";
      type = "file";
      create = true;
      size = "1K";
      preserve = false;
    }
    {
      device = "copied.img";
      type = "file";
      create = true;
      image = sourceImage;
      preserve = false;
    }
    {
      device = "external.img";
      type = "file";
      create = false;
    }
  ];
  failing = mkPreparation [
    {
      device = "copied.img";
      type = "file";
      create = true;
      image = "/missing-osvm-source.img";
      preserve = false;
    }
  ];
in
pkgs.runCommand "qemu-disk-lifecycle" { inherit sourceImage; } ''
  ${prepare}
  printf retained > data.img
  printf changed > scratch.img
  printf changed > copied.img
  printf external > external.img
  ${prepare}
  test "$(cat data.img)" = retained
  test "$(stat -c %s scratch.img)" = 1024
  cmp -n 1024 scratch.img /dev/zero
  cmp copied.img "$sourceImage"
  test "$(cat external.img)" = external
  if ${failing}; then
    echo "copying a missing source succeeded" >&2
    exit 1
  fi
  cmp copied.img "$sourceImage"
  test -z "$(find . -name 'osvm-disk-*' -print)"
  touch "$out"
''
