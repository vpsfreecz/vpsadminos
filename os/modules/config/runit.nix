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
    # load kernel modules
    for x in ${lib.concatStringsSep " " config.boot.kernelModules}; do
      modprobe $x
    done

    # Apply kernel parameters
    sysctl -w --system

    ip addr add 127.0.0.1/8 dev lo
    ip link set lo up

    # enable IP forwarding
    echo 1 > /proc/sys/net/ipv4/ip_forward
    echo 1 > /proc/sys/net/ipv6/conf/all/forwarding

    # disable DPMS on tty's
    echo -ne "\033[9;0]" > /dev/tty0

    # runit
    runlevel=${config.runit.defaultRunlevel}
    for o in $(cat /proc/cmdline); do
      case $o in
        1)
          runlevel=single
          ;;
        runlevel=*)
          set -- $(IFS==; echo $o)
          runlevel=$2
          ;;
      esac
    done

    ln -sfn /etc/runit/runsvdir/$runlevel /etc/runit/runsvdir/current
    ln -sfn /etc/runit/runsvdir/current /service
    mkdir /run/service

    # LXC
    mkdir -p /var/lib/lxc/rootfs

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

    if ${if config.vpsadmin.enable then "true" else "false"} ; then
      mkdir -m 0700 /run/nodectl
      ln -sfn /run/current-system/sw/bin/nodectl /run/nodectl/nodectl
    fi

    # /etc/fstab
    mount -a

    touch /etc/runit/stopit
    chmod 0 /etc/runit/stopit
  '';

  runit.stage2 = ''
    export PATH=/run/current-system/sw/bin
    exec runsvdir -P /service
  '';

  runit.stage3 = ''
    osctl shutdown --force
    hwclock -w
    echo and down we go
  '';
}
