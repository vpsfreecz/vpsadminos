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
              require 'shellwords'
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

              begin
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

                ${pkgs.lib.optionalString (distribution == "centos" && version == "7") ''
                  # Cover the supported old daemon both disabled and managing
                  # this same guest. Selecting NM is fixture setup, not a host
                  # resolver policy change or an image/package upgrade.
                  machine.all_succeed(
                    "osctl ct exec #{testct} nmcli --version | grep -F '1.18.'",
                    "osctl ct exec #{testct} systemctl stop NetworkManager.service",
                    "osctl ct set dns-resolver #{testct} 192.0.2.53",
                    "osctl ct exec #{testct} grep -Fx 'nameserver 192.0.2.53' /etc/resolv.conf",
                    "osctl ct unset dns-resolver #{testct}",
                    "osctl ct exec #{testct} systemctl is-active network.service",
                    "ping -c 1 #{ip}",
                  )
                  expect(failed_units.call).to eq(initial_failed_units)
                  machine.all_succeed(
                    "osctl ct exec #{testct} systemctl unmask NetworkManager.service",
                    "osctl ct exec #{testct} systemctl enable NetworkManager.service",
                    "osctl ct exec #{testct} systemctl disable network.service",
                    "osctl ct exec #{testct} sh -c 'printf \"[main]\\ndns=default\\nrc-manager=file\\n\" > /etc/NetworkManager/conf.d/00-test-dns.conf'",
                    "osctl ct restart #{testct}",
                    "osctl ct exec #{testct} systemctl is-active NetworkManager.service",
                  )
                  connection = machine.succeeds("osctl ct exec #{testct} nmcli -t -f GENERAL.CONNECTION device show eth0")[1].strip.split(':', 2).last
                  machine.all_succeed(
                    "osctl ct exec #{testct} nmcli connection modify #{connection.shellescape} ipv4.dns 10.0.2.3 ipv4.ignore-auto-dns yes",
                    "osctl ct exec #{testct} nmcli device reapply eth0",
                    "osctl ct exec #{testct} grep -Fx 'nameserver 10.0.2.3' /etc/resolv.conf",
                  )
                  nm_failed_units = failed_units.call
                  unless (nm_failed_units - host_only_units).empty?
                    machine.succeeds("osctl ct exec #{testct} journalctl -b --no-pager")
                  end
                  expect(nm_failed_units - host_only_units).to eq([])
                  old_init = machine.osctl_json("ct show #{testct}").fetch('init_pid')
                  old_connection = machine.succeeds("osctl ct exec #{testct} nmcli -t -f GENERAL.STATE,GENERAL.CON-PATH device show eth0")[1]
                  refresh = "osctl ct exec #{testct} dbus-send --system --print-reply --type=method_call --dest=org.freedesktop.NetworkManager /org/freedesktop/NetworkManager org.freedesktop.NetworkManager.Reload uint32:2"
                  machine.all_succeed(
                    "osctl ct set dns-resolver #{testct} 192.0.2.53",
                    refresh,
                    "osctl ct exec #{testct} grep -Fx 'nameserver 192.0.2.53' /etc/resolv.conf",
                    "ping -c 1 #{ip}",
                    "osctl ct unset dns-resolver #{testct}",
                    "osctl ct exec #{testct} grep -Fx 'nameserver 10.0.2.3' /etc/resolv.conf",
                    "osctl ct set dns-resolver #{testct} 192.0.2.54",
                    refresh,
                    "osctl ct exec #{testct} grep -Fx 'nameserver 192.0.2.54' /etc/resolv.conf",
                    "osctl ct unset dns-resolver #{testct}",
                    "osctl ct exec #{testct} grep -Fx 'nameserver 10.0.2.3' /etc/resolv.conf",
                    "osctl ct exec #{testct} systemctl is-active NetworkManager.service",
                    "ping -c 1 #{ip}",
                  )
                  expect(failed_units.call).to eq(nm_failed_units)
                  expect(machine.osctl_json("ct show #{testct}").fetch('init_pid')).to eq(old_init)
                  expect(machine.succeeds("osctl ct exec #{testct} nmcli -t -f GENERAL.STATE,GENERAL.CON-PATH device show eth0")[1]).to eq(old_connection)
                ''}

              ensure
                # A failing script must not leave its routed address behind for
                # the next distribution. Retain diagnostics BEFORE destroying
                # the guest, and never replace its primary failure with cleanup.
                primary_error = $!
                if primary_error
                  [
                    'systemctl --failed --plain --no-legend --no-pager',
                    'journalctl -b -p err -n 80 --no-pager',
                    # Record access failures without changing the guest or its units.
                    "sh -c #{<<~'ACCESS'.shellescape}",
                      {
                        printf '\n--- guest access state ---\n'
                        id
                        stat -Lc '%n %F %a %u:%g %t:%T' /dev /dev/null /dev/console /dev/tty /dev/pts /sys/fs/cgroup
                        if command -v getfacl >/dev/null 2>&1; then
                          getfacl -p /dev/null /dev/console
                        fi
                        for process in self 1; do
                          printf '\n--- /proc/%s namespace and credentials ---\n' "$process"
                          cat /proc/$process/cgroup /proc/$process/uid_map /proc/$process/gid_map
                          grep -E '^(Name|Uid|Gid|Groups|CapInh|CapPrm|CapEff|CapBnd|NoNewPrivs|Seccomp):' /proc/$process/status
                        done
                        printf '\n--- init mount table ---\n'
                        head -c 16384 /proc/1/mountinfo
                        printf '\n--- failed unit settings and cgroup ownership (up to 8) ---\n'
                        systemctl --failed --plain --no-legend --no-pager | head -n 8 |
                        while read -r unit rest; do
                          properties=$(systemctl show --no-pager -p Id -p Result -p ExecMainStatus \
                            -p ExecStart -p StandardInput -p TTYPath -p User -p Group \
                            -p ControlGroup -p FragmentPath -p DropInPaths -- "$unit")
                          printf '\n%s\n' "$properties"
                          cg=$(printf '%s\n' "$properties" | sed -n 's/^ControlGroup=//p')
                          if test -n "$cg"; then
                            for root in /sys/fs/cgroup /sys/fs/cgroup/systemd; do
                              stat -Lc '%n %F %a %u:%g' "$root$cg" "$root$cg/cgroup.procs" \
                                "$root$cg/tasks" "$(dirname "$root$cg")"
                            done
                          fi
                        done
                      } 2>&1 | head -c 65536
                    ACCESS
                  ].each do |diagnostic|
                    begin
                      status, output = machine.execute("osctl ct exec #{testct} #{diagnostic}", timeout: 30)
                      warn "Guest #{testct} diagnostic (#{status}): #{diagnostic}\n#{output}"
                    rescue StandardError => e
                      warn "Guest #{testct} diagnostic failed: #{e.class}: #{e.message}"
                    end
                  end
                end

                begin
                  machine.all_succeed(
                    "osctl ct del -f --prune #{testct}",
                    "osctl repository images prune"
                  )
                rescue StandardError => cleanup_error
                  raise unless primary_error

                  warn "Guest #{testct} cleanup failed after #{primary_error.class}: #{cleanup_error.class}: #{cleanup_error.message}"
                end
              end
            '';
          };
        }
      ) distributions
    );
  }
)
