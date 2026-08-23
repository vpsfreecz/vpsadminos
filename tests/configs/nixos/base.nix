{
  config,
  lib,
  pkgs,
  ...
}:
let
  shellIndexes = lib.range 0 (config.osvm.testShells - 1);

  testShell =
    i:
    let
      device = "/dev/hvc${toString i}";
    in
    pkgs.writeShellScript "osvm-test-shell-${toString i}" ''
      until [ -c ${device} ]; do
        echo "Waiting for ${device}"
        sleep 1
      done

      export USER=root
      export HOME=/root

      if [ -e /etc/profile ]; then
        source /etc/profile
      fi

      export PAGER=
      export PS1=

      stty -F ${device} raw -echo

      echo test-shell-ready > ${device}

      exec ${pkgs.bash}/bin/bash --norc ${device}
    '';

  serviceName = i: if i == 0 then "test-shell" else "test-shell-${toString i}";

  shellService =
    i:
    let
      device = "/dev/hvc${toString i}";
    in
    {
      description = "osvm test shell";
      wantedBy = [ "multi-user.target" ];
      after = [ "dev-hvc${toString i}.device" ];
      restartIfChanged = false;
      stopIfChanged = false;
      reloadIfChanged = false;
      serviceConfig = {
        Type = "simple";
        StandardInput = "tty";
        StandardOutput = "tty";
        StandardError = "tty";
        TTYPath = device;
        TTYReset = "yes";
        TTYVHangup = "yes";
        ExecStart = testShell i;
        Restart = "always";
        RestartSec = 1;
      };
    };
in
{
  options.osvm.testShells = lib.mkOption {
    type = lib.types.ints.positive;
    default = 1;
    description = "Number of test shells to run.";
  };

  config = {
    boot.loader.grub.enable = false;
    boot.loader.generic-extlinux-compatible.enable = false;
    boot.loader.systemd-boot.enable = false;

    # Linux 6.18's executable-memory cache can race during parallel module
    # loading and Oops in __execmem_cache_free. Serializing udev workers did
    # not prevent other module loaders from racing. Keep generated test VMs on
    # 6.12 until 1871d548fc4feb007644efb6d669c93a4e191254 is in linux-6.18.y
    # and the pinned nixpkgs contains that release. Before removing the pin,
    # stress parallel boot and module loading and confirm that neither this
    # failure nor the earlier __text_poke static-call failure recurs.
    boot.kernelPackages = lib.mkDefault pkgs.linuxPackages_6_12;

    boot.kernelParams = [ "console=ttyS0" ];

    boot.initrd.availableKernelModules = [
      "ahci"
      "virtio_pci"
      "virtio_blk"
      "virtio_console"
      "virtio_net"
      "virtiofs"
    ];

    boot.kernelModules = [ "virtiofs" ];

    boot.supportedFilesystems = {
      ext4 = true;
      virtiofs = true;
    };

    fileSystems."/" = {
      device = "/dev/disk/by-label/nixos";
      fsType = "ext4";
    };

    networking.hostName = lib.mkDefault "nixos";
    networking.useDHCP = lib.mkDefault false;
    # NixOS test VMs use stable ethX names via qemu-vm.nix.
    networking.interfaces.eth0.useDHCP = lib.mkDefault true;
    networking.nameservers = lib.mkDefault [ "10.0.2.3" ];

    time.timeZone = "UTC";

    users.users.root.initialPassword = "";
    security.sudo.wheelNeedsPassword = false;

    services.getty.helpLine = "";
    services.getty.autologinUser = lib.mkDefault "root";
    services.qemuGuest.enable = true;

    environment.systemPackages = with pkgs; [
      bash
      coreutils
      curl
      iproute2
      iputils
      jq
    ];

    system.stateVersion = lib.trivial.release;

    systemd.services =
      builtins.listToAttrs (
        map (i: {
          name = serviceName i;
          value = shellService i;
        }) shellIndexes
      )
      // {
        "serial-getty@hvc0".enable = false;
      };
  };
}
