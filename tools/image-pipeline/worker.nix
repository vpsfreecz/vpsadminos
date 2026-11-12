# A guest closure, not a test execution. The coordinator creates run-owned
# workers from this JSON and keeps each guest alive for multiple assignments.
{
  memoryMiB,
  cpus,
  diskSize,
}:
assert builtins.isInt memoryMiB && memoryMiB > 0;
assert builtins.isInt cpus && cpus > 0;
let
  source = builtins.getFlake (toString ../../.);
in
(import ../../tests/make-test.nix (_: {
  name = "image-pipeline-worker";
  description = "Run-owned container image worker";
  machine = {
    disks = [
      {
        type = "file";
        device = "images.img";
        size = diskSize;
      }
    ];
    config = {
      imports = [ ../../tests/configs/vpsadminos/pool-tank.nix ];
      boot.qemu.memory = memoryMiB;
      boot.qemu.cpus = cpus;
      boot.qemu.cpu = {
        cores = cpus;
        threads = 1;
        sockets = 1;
      };
      os.channel-registration.enable = true;
    };
  };
  testScript = "";
}) { pkgs = source.inputs.nixpkgs; }).json
