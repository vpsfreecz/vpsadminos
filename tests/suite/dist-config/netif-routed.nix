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

              # Connectivity and guest service health must hold in the SAME
              # container: host-side address application can hide a failed
              # guest network service (notably NixOS EEXIST failures).
              ${
                if distribution == "centos" && version == "7" then
                  ''
                    # systemd 219 does not implement is-system-running --wait.
                    machine.wait_until_succeeds("osctl ct exec #{testct} sh -c 's=$(systemctl is-system-running); test \"$s\" != initializing -a \"$s\" != starting'")
                    # The archived image enables these host-only units. Do not
                    # mask/reset them to turn a degraded boot green: assert the
                    # actual network service and reject any other failed unit.
                    host_only_units = %w[
                      dev-hugepages.mount auditd.service kdump.service
                      plymouth-start.service systemd-sysctl.service tuned.service
                    ]
                    failed_units = lambda do
                      machine.succeeds("osctl ct exec #{testct} systemctl --failed --plain --no-legend --no-pager")[1].lines.map { |line| line.split.first }.sort
                    end
                    initial_failed_units = failed_units.call
                    expect(initial_failed_units - host_only_units).to eq([])
                    machine.succeeds("osctl ct exec #{testct} systemctl is-active network.service")
                  ''
                else
                  ''
                    machine.succeeds(
                      "osctl ct exec #{testct} sh -c 'if test -d /run/systemd/system; then systemctl is-system-running --wait; fi'"
                    )
                  ''
              }

              ${pkgs.lib.optionalString (distribution == "nixos") ''
                machine.succeeds("osctl ct exec #{testct} systemctl is-active networking-setup.service")
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
