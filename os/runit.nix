{ lib, config, pkgs, ... }:
with lib;

let
  compat = pkgs.runCommand "runit-compat" {} ''
    mkdir -p $out/bin/
    cat << EOF > $out/bin/poweroff
#!/bin/sh
exec runit-init 0
EOF
    cat << EOF > $out/bin/reboot
#!/bin/sh
exec runit-init 6
EOF
    chmod +x $out/bin/{poweroff,reboot}
  '';

  apparmor_paths = [ pkgs.apparmor-profiles ] ++ config.security.apparmor.packages;
  apparmor_paths_include = concatMapStrings (s: " -I ${s}/etc/apparmor.d") apparmor_paths;
  profile = "${pkgs.lxc}/etc/apparmor.d/lxc-containers";
in
{
  environment.systemPackages = [ compat pkgs.socat ];

  runit.stage1 = ''
    # Apply kernel parameters
    sysctl -p /etc/sysctl.d/nixos.conf

    # load kernel modules
    for x in ${lib.concatStringsSep " " config.boot.kernelModules}; do
      modprobe $x
    done

    ip addr add 127.0.0.1/8 dev lo
    ip link set lo up

    # enable IP forwarding
    echo 1 > /proc/sys/net/ipv4/ip_forward
    echo 1 > /proc/sys/net/ipv6/conf/all/forwarding

    # disable DPMS on tty's
    echo -ne "\033[9;0]" > /dev/tty0

    # runit
    ln -sfn /etc/service /service

    # LXC
    mkdir -p /var/lib/lxc/rootfs

    # Suids
    chmod 04755 $( which su )
    chmod 04755 $( which newuidmap )
    chmod 04755 $( which newgidmap )
    chmod 04755 ${pkgs.lxc}/libexec/lxc/lxc-user-nic

    # CGroups
    mount -t tmpfs -o uid=0,gid=0,mode=0755 cgroup /sys/fs/cgroup
    mkdir /sys/fs/cgroup/unified
    mount -t cgroup2 none /sys/fs/cgroup/unified
    cgconfigparser -l /etc/cgconfig.conf

    # AppArmor
    mount -t securityfs securityfs /sys/kernel/security
    ${pkgs.apparmor-parser}/bin/apparmor_parser -rKv ${apparmor_paths_include} "${profile}"

    # DebugFS
    mount -t debugfs none /sys/kernel/debug/

    # Permission fixes
    chmod 777 /tmp

    # ZFS
    zpool status ${config.boot.zfs.pool.name} &> /dev/null && zfs mount -a

    if ${if config.vpsadmin.enable then "true" else "false"} ; then
      mkdir -m 0700 /run/nodectl
      ln -sfn /run/current-system/sw/bin/nodectl /run/nodectl/nodectl
    fi

    touch /etc/runit/stopit
    chmod 0 /etc/runit/stopit
  '';

  runit.stage2 = ''
    exec runsvdir -P /etc/service
  '';

  runit.stage3 = ''
    osctl shutdown --force
    echo and down we go
  '';
}
