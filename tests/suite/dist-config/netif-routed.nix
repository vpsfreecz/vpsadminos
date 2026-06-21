import ../../make-test.nix (
  { pkgs, distributions }:
  {
    name = "dist-config-netif-routed";

    description = ''
      Test that routed network interface works in containers
    '';

    tags = [ "ci" ];

    machine = import ../../machines/vpsadminos/tank.nix pkgs;

    testScripts = builtins.listToAttrs (
      map (
        { distribution, version }:
        {
          name = "${distribution}-${version}";
          value = {
            script = ''
              # CentOS 7 requires cgroups v1, all other distributions use v2
              kernel_params = ["osctl.cgroupv=${if distribution != "centos" || version != "7" then "2" else "1"}"]

              if machine.running? && machine.start_kernel_params != kernel_params
                machine.stop
              end

              machine.start(kernel_params:) unless machine.running?
              machine.wait_for_osctl_pool("tank")
              machine.wait_until_online

              ip = "1.2.3.4"

              machine.fails("ping -c 1 #{ip}")

              testct = get_container_id

              machine.all_succeed(
                "osctl ct new --distribution ${distribution} --version ${version} #{testct}",
                "osctl ct netif new routed #{testct} eth0",
                "osctl ct netif ip add #{testct} eth0 #{ip}/32",
                "osctl ct start #{testct}",
              )

              machine.wait_until_succeeds("ping -c 1 #{ip}")

              ${pkgs.lib.optionalString (distribution == "fedora") ''
                # The published Fedora image deliberately has dns=none in
                # vpsadminos.conf. Select guest-managed DNS explicitly for
                # this set/unset test, retaining its rc-manager policy. This
                # is test setup, not an osctld rewrite of guest policy.
                machine.all_succeed(
                  "osctl ct exec #{testct} systemctl is-active NetworkManager.service",
                  "osctl ct exec #{testct} grep -Fx dns=none /etc/NetworkManager/conf.d/vpsadminos.conf",
                  "osctl ct exec #{testct} sed -i '/^dns=none$/d' /etc/NetworkManager/conf.d/vpsadminos.conf",
                  "osctl ct exec #{testct} nmcli general reload conf,dns-rc",
                  "osctl ct exec #{testct} nmcli connection modify eth0 ipv4.dns 10.0.2.3 ipv4.ignore-auto-dns yes",
                  "osctl ct exec #{testct} nmcli device reapply eth0",
                  "osctl ct exec #{testct} grep -Fx 'nameserver 10.0.2.3' /etc/resolv.conf",
                  "osctl ct set dns-resolver #{testct} 192.0.2.53",
                  "osctl ct exec #{testct} nmcli general reload dns-rc",
                  "osctl ct exec #{testct} grep -Fx 'nameserver 192.0.2.53' /etc/resolv.conf",
                  "osctl ct unset dns-resolver #{testct}",
                  "osctl ct exec #{testct} grep -Fx 'nameserver 10.0.2.3' /etc/resolv.conf",
                  "osctl ct exec #{testct} systemctl is-system-running --wait",
                  "ping -c 1 #{ip}",
                )
              ''}

              machine.all_succeed(
                "osctl ct del -f --prune #{testct}",
                "osctl repository images prune"
              )
            '';
          };
        }
      ) distributions
    );
  }
)
