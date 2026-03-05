{
  config,
  lib,
  pkgs,
  ...
}:
let
  testShell = pkgs.writeShellScript "osvm-test-shell" ''
    until [ -c /dev/hvc0 ]; do
      echo "Waiting for /dev/hvc0"
      sleep 1
    done

    export USER=root
    export HOME=/root

    if [ -e /etc/profile ]; then
      source /etc/profile
    fi

    export PAGER=
    export PS1=

    stty -F /dev/hvc0 raw -echo

    echo test-shell-ready > /dev/hvc0

    exec ${pkgs.bash}/bin/bash --norc /dev/hvc0
  '';
in
{
  boot.loader.grub.enable = false;
  boot.loader.generic-extlinux-compatible.enable = false;
  boot.loader.systemd-boot.enable = false;

  boot.kernelParams = [
    "console=ttyS0"
  ];

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
  systemd.services."serial-getty@hvc0".enable = false;

  environment.systemPackages = with pkgs; [
    bash
    coreutils
    curl
    iproute2
    iputils
    jq
  ];

  system.stateVersion = lib.trivial.release;

  systemd.services.test-shell = {
    description = "osvm test shell";
    wantedBy = [ "multi-user.target" ];
    after = [ "dev-hvc0.device" ];
    serviceConfig = {
      Type = "simple";
      StandardInput = "tty";
      StandardOutput = "tty";
      StandardError = "tty";
      TTYPath = "/dev/hvc0";
      TTYReset = "yes";
      TTYVHangup = "yes";
      ExecStart = testShell;
      Restart = "always";
      RestartSec = 1;
    };
  };

  virtualisation.memorySize = lib.mkDefault 2048;
  virtualisation.cores = lib.mkDefault 2;
  virtualisation.mountHostNixStore = lib.mkForce false;
  virtualisation.sharedDirectories = lib.mkForce { };
}
