{ config, ...}:
{
  system.qemuParams = [
    "-drive index=0,id=drive1,file=${config.system.build.squashfs},readonly,media=cdrom,format=raw,if=virtio"
    "-kernel ${config.system.build.kernel}/bzImage -initrd ${config.system.build.initialRamdisk}/initrd"
    "-append \"console=ttyS0 systemConfig=${config.system.build.toplevel} ${toString config.boot.kernelParams} quiet panic=-1\""
    "-nographic"
    "-virtfs local,path=../../,mount_tag=hostNixPath,security_model=passthrough,id=hostNixPath"
    "-virtfs local,path=../,mount_tag=hostOs,security_model=passthrough,id=hostOs"
    ];

  # Generate /etc/fstab
  fileSystems."/mnt/nix-path" = {
    device = "hostNixPath";
    fsType = "9p";
    options = [ "trans=virtio" "version=9p2000.L" ];
  };

  fileSystems."/mnt/vpsadminos" = {
    device = "hostOs";
    fsType = "9p";
    options = [ "trans=virtio" "version=9p2000.L" ];
  };

  # These commands will be run right before runit is executed
  boot.postActivate = ''
    # Module 9pnet_virtio is needed for the mounts to work
    modprobe 9pnet_virtio

    # Create mountpoints and mount the directories
    mkdir -p /mnt/nix-path /mnt/vpsadminos
    mount -a
  '';

  nix.nixPath = [ "/mnt/nix-path" ];
}
