{ lib, config, pkgs, ... }:
with lib;

let
  sshd_config = pkgs.writeText "sshd_config" ''
    HostKey /etc/ssh/ssh_host_rsa_key
    HostKey /etc/ssh/ssh_host_ed25519_key
    UsePAM yes
    Port 22
    PidFile /run/sshd.pid
    Protocol 2
    PermitRootLogin yes
    PasswordAuthentication yes
    ChallengeResponseAuthentication no

    Match User root
      AuthorizedKeysFile /etc/ssh/authorized_keys.d/%u

    Match User migration
      PasswordAuthentication no
      AuthorizedKeysFile /run/osctl/migration/authorized_keys
  '';
  syslog_config = pkgs.writeText "syslog.conf" ''
    $ModLoad imuxsock
    $WorkDirectory /var/spool/rsyslog

    # "local1" is used for dhcpd messages.
    local1.*                     -/var/log/dhcpd

    mail.*                       -/var/log/mail

    local2.*                     -/var/log/osctld
    local3.*                     -/var/log/nodectld

    *.=warning;*.=err            -/var/log/warn
    *.crit                        /var/log/warn

    *.*;mail.none;local1.none    -/var/log/messages
  '';

  chrony_config = pkgs.writeText "chrony_config" ''
    ${concatMapStringsSep "\n" (server: "server " + server) config.networking.timeServers}
    initstepslew 1000
    pidfile /run/chronyd.pid
  '';

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
  apparmor_paths_joined = concatMapStringsSep ":" (s: "${s}/etc/apparmor.d") apparmor_paths;
  profile = "${pkgs.lxc}/etc/apparmor.d/lxc-containers";
in
{
  environment.systemPackages = [ compat pkgs.socat ];

  runit.stage1 = ''
    #!${pkgs.stdenv.shell}

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
    ln -s /etc/service /service

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
      ln -s /run/current-system/sw/bin/nodectl /run/nodectl/nodectl
    fi

    touch /etc/runit/stopit
    chmod 0 /etc/runit/stopit
  '';

  runit.stage2 = ''
    #!/bin/sh
    exec runsvdir -P /etc/service
  '';

  runit.stage3 = ''
    #!/bin/sh
    osctl shutdown --force
    echo and down we go
  '';

  runit.services = lib.mkMerge [
    {
      sshd.run = ''
        #!/bin/sh
        exec ${pkgs.openssh}/bin/sshd -D -f ${sshd_config}
      '';

      lxcfs.run = ''
        #!/bin/sh
        mkdir -p /var/lib/lxcfs
        mkdir -p /var/log

        exec 1<&-                     # Close STDOUT file descriptor
        exec 2<&-                     # Close STDERR FD
        exec 1<>/var/log/lxcfs.output # Open STDOUT as file for read and write
        exec 2>&1                     # Redirect STDERR to STDOUT

        exec ${pkgs.lxcfs}/bin/lxcfs -l /var/lib/lxcfs
      '';

      networking.run = with config.networking; ''
        #!/bin/sh -e
        sv check eudev-trigger >/dev/null || exit 1

        ${config.networking.preConfig}

        ${lib.optionalString static.enable ''
        ip addr add ${static.ip} dev ${static.interface}
        ip link set ${static.interface} up
        ip route add ${static.route} dev ${static.interface}
        ip route add default via ${static.gw} dev ${static.interface}
        ''}

        ${lib.optionalString config.networking.dhcp ''
        ${pkgs.dhcpcd.override { udev = null; }}/sbin/dhcpcd
        ''}

        ${lib.optionalString config.networking.lxcbr ''
        brctl addbr lxcbr0
        brctl setfd lxcbr0 0
        ip addr add 192.168.1.1 dev lxcbr0
        ip link set promisc on lxcbr0
        ip link set lxcbr0 up
        ip route add 192.168.1.0/24 dev lxcbr0
        iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
        ''}

        ${config.networking.custom}

        touch /run/net-done
        exec sleep inf
      '';

      networking.check = ''
        #!/bin/sh -e
        test -f /run/net-done
      '';

      osctld.run = ''
        #!/bin/sh

        export PATH="$PATH:${pkgs.apparmor-parser}/bin"
        export OSCTLD_APPARMOR_PATHS="${apparmor_paths_joined}"

        exec 2>&1
        exec ${pkgs.osctld}/bin/osctld --log syslog --log-facility local2
      '';
      
      rsyslog.run = ''
        #!/bin/sh
        mkdir -p /var/spool/rsyslog
        exec ${pkgs.rsyslog-light}/sbin/rsyslogd -f ${syslog_config} -n -i /run/rsyslog.pid
      '';
    }

    (mkIf (config.vpsadminos.nix) {
      nix.run = ''
        #!/bin/sh
        nix-store --load-db < /nix/store/nix-path-registration
        exec nix-daemon
      '';
    })

    (mkIf (config.networking.dhcpd) {
      dhcpd.run = ''
        #!/bin/sh
        sv check networking >/dev/null || exit 1
        mkdir -p /var/lib/dhcp
        touch /var/lib/dhcp/dhcpd4.leases
        exec ${pkgs.dhcp}/sbin/dhcpd -4 -f \
          -pf /run/dhcpd4.pid \
          -cf /etc/dhcpd/dhcpd4.conf \
          -lf /var/lib/dhcp/dhcpd4.leases \
          lxcbr0
      '';
    })

    (mkIf (config.networking.chronyd) {
      chronyd.run = ''
        #!/bin/sh
        exec ${pkgs.chrony}/bin/chronyd -n -m -u chrony -f ${chrony_config}
      '';
    })
  ];
}
