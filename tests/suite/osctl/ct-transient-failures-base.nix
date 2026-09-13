{ name, config }:
import ../../make-test.nix (
  { pkgs }:
  let
    guestShell = pkgs.writeText "transient-fault-shell" ''
      #!/bin/busybox sh
      case "$1" in
        /.runscript*.sh)
          echo entered > /transient-entered
          case "$(/bin/busybox cat /transient-mode)" in
            missing) exec /bin/busybox sleep 300 ;;
            partial) printf rea; exec /bin/busybox sleep 300 ;;
            malformed) printf 'wrong\n'; exec /bin/busybox sleep 300 ;;
            early_exit) exit 42 ;;
          esac
          ;;
      esac
      exec /bin/busybox sh "$@"
    '';
    payload = pkgs.writeScript "transient-failure-payload" ''
      #!/bin/sh
      echo must-not-run > /root/unexpected-payload
    '';
  in
  {
    name = "osctl-ct-transient-failures-${name}";
    description = "Bound transient startup failures and clean up real helpers on ${name}";
    tags = [ "ci" ];

    machine = import ../../machines/vpsadminos/with-tank.nix {
      inherit pkgs;
      config = { lib, ... }: {
        imports = [ config ];
        # Two small Alpine guests and bounded startup failure probes do not
        # need the general suite's 8 GiB default.
        boot.qemu.memory = lib.mkForce 4096;
      };
    };

    testScript = ''
      require 'shellwords'

      machine.start
      machine.wait_for_osctl_pool('tank')
      machine.wait_until_online
      machine.push_file('${guestShell}', '/root/transient-fault-shell')
      machine.push_file('${payload}', '/root/transient-failure-payload')
      machine.succeeds('chmod 500 /root/transient-failure-payload')
      machine.all_succeed(
        'osctl ct new --distribution alpine stalled',
        'osctl ct unset start-menu stalled',
        'osctl ct netif new routed stalled eth0',
        'osctl ct netif ip add stalled eth0 192.0.2.60/32',
        # Row 23: the transient bodies must exercise a dual-stack,
        # multi-interface topology, not routed IPv4 alone.
        'osctl ct netif new routed stalled eth1',
        'osctl ct netif ip add stalled eth1 2001:db8:1::60/128',
        # These are host ingress routes into the routed container, not guest
        # default routes. They must exist only while its veth is live.
        'osctl ct netif route add --via 192.0.2.60 stalled eth0 198.51.100.0/24',
        'osctl ct netif route add --via 2001:db8:1::60 stalled eth1 2001:db8:2::/64',
        'osctl ct mount stalled',
        'osctl ct new --distribution alpine sibling',
        'osctl ct unset start-menu sibling',
        'osctl ct netif new routed sibling eth0',
        'osctl ct netif ip add sibling eth0 192.0.2.61/32',
        'osctl ct netif new routed sibling eth1',
        'osctl ct netif ip add sibling eth1 2001:db8:1::61/128',
        'osctl ct start sibling',
      )
      machine.wait_until_succeeds('osctl ct exec sibling rc-service networking status')
      machine.succeeds("osctl ct exec sibling sh -c 'echo sibling-data > /root/retained'")
      sibling_init = machine.osctl_json('ct show sibling').fetch('init_pid')
      rootfs = Shellwords.escape(machine.osctl_json('ct show stalled').fetch('rootfs'))
      machine.all_succeed(
        "test -L #{rootfs}/bin/sh",
        "rm #{rootfs}/bin/sh",
        "install -m 555 /root/transient-fault-shell #{rootfs}/bin/sh",
      )
      host_loopback = machine.succeeds('ip -o address show dev lo')[1]

      # Intercept only the generated transient init script inside this guest.
      # No daemon code or timeout is replaced: exercise actual LXC, pipes,
      # private readiness transport and the production cleanup bounds.
      %w[missing partial malformed early_exit].each do |mode|
        ['exec -rn stalled touch /root/unexpected-payload', 'runscript -rn stalled /root/transient-failure-payload'].each do |operation|
          machine.all_succeed(
            "echo #{mode} > #{rootfs}/transient-mode",
            "rm -f #{rootfs}/transient-entered #{rootfs}/root/unexpected-payload",
          )
          started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          status, output = machine.execute("timeout 90 osctl ct #{operation}", timeout: 100)
          expect(status).not_to eq(0)
          expect([124, 137]).not_to include(status)
          expect(output).to include('error:')
          expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 90
          machine.all_succeed(
            "grep -Fx entered #{rootfs}/transient-entered",
            "test ! -e #{rootfs}/root/unexpected-payload",
          )
          # Keep a stuck client inside a guest timeout, not the test-shell
          # protocol deadline. Otherwise the transport becomes unusable before
          # we can collect daemon backtraces and the surviving process tree.
          state_status, state_output = machine.execute('timeout 30 osctl ct show -H -o state stalled', timeout: 45)
          if state_status != 0 || state_output.strip != 'stopped'
            machine.execute('ps -eo pid,ppid,stat,wchan:32,args', timeout: 30)
            machine.execute('timeout 10 osctl debug threads ls', timeout: 20)
            machine.execute('timeout 10 osctl debug locks ls -v', timeout: 20)
            machine.execute('tail -n 150 /var/log/osctld/current', timeout: 20)
            machine.execute('find /run/osctl/cgroup -path "*stalled*" -name cgroup.procs -print -exec cat {} \\;', timeout: 20)
            fail "stalled state query failed: status=#{state_status}, output=#{state_output.inspect}"
          end
          stopped = machine.osctl_json('ct show stalled')
          expect(stopped.fetch('recovery_tainted')).to be(false)
          expect(stopped.fetch('init_pid')).to be_nil
          machine.wait_until_succeeds('test -z "$(ip -4 route show 198.51.100.0/24)" && test -z "$(ip -6 route show 2001:db8:2::/64)"', timeout: 30)
          # The monitor can still be finishing a bounded state query after a
          # very short-lived init exits. Require convergence, not an atomic
          # snapshot that mistakes that legitimate query for a leaked helper.
          machine.wait_until_succeeds("! ps -eo args= | grep -E '^osctld: tank:stalled runner:'", timeout: 30)
          expect(machine.osctl_json('ct show sibling').fetch('init_pid')).to eq(sibling_init)
          expect(machine.succeeds('ip -o address show dev lo')[1]).to eq(host_loopback)
          machine.all_succeed(
            'osctl ct exec sibling grep -Fx sibling-data /root/retained',
            'ping -c 1 192.0.2.61',
            'ping -c 1 2001:db8:1::61',
            "! ip -6 route show | grep -F '2001:db8:1::60'",
          )
        end
      end

      # A failed transient run must release locks/state for both another
      # transient payload and ordinary guest startup without a daemon restart.
      machine.all_succeed(
        "echo normal > #{rootfs}/transient-mode",
        'osctl ct exec -rn stalled ping -c 1 255.255.255.254',
        'osctl ct exec -rn stalled ping -6 -c 1 2001:db8:1::61',
        'osctl ct runscript -rn stalled /root/transient-failure-payload',
        "grep -Fx must-not-run #{rootfs}/root/unexpected-payload",
      )
      # Observe the host routes while the real transient helper is alive;
      # waiting until it exits would only prove post-stop cleanup. Keep the
      # finite guest payload and outer test bound separate from daemon timeouts.
      machine.succeeds(
        %q{timeout 75 sh -ec 'osctl ct exec -rn stalled sh -c "sleep 8" & child=$!; trap "kill $child 2>/dev/null || true" EXIT; for i in $(seq 1 600); do if ip -4 route show 198.51.100.0/24 | grep -Fq "via 192.0.2.60" && ip -6 route show 2001:db8:2::/64 | grep -Fq "via 2001:db8:1::60"; then wait "$child"; exit 0; fi; sleep 0.1; done; wait "$child"; exit 1'}
      )
      machine.wait_until_succeeds('test "$(osctl ct show -H -o state stalled)" = stopped', timeout: 60)
      machine.wait_until_succeeds('test -z "$(ip -4 route show 198.51.100.0/24)" && test -z "$(ip -6 route show 2001:db8:2::/64)"', timeout: 30)
      machine.succeeds('osctl ct start stalled')
      machine.wait_until_succeeds('osctl ct exec stalled rc-service networking status')
      machine.wait_until_succeeds('ping -c 1 192.0.2.60')
      machine.wait_until_succeeds('osctl ct exec stalled ip -6 addr show dev eth1 | grep -F 2001:db8:1::60')
      machine.wait_until_succeeds('ping -c 1 2001:db8:1::60')
      machine.wait_until_succeeds('ip -4 route show 198.51.100.0/24 | grep -F "via 192.0.2.60"')
      machine.wait_until_succeeds('ip -6 route show 2001:db8:2::/64 | grep -F "via 2001:db8:1::60"')
      machine.succeeds('osctl ct stop stalled')
      machine.wait_until_succeeds('test -z "$(ip -4 route show 198.51.100.0/24)" && test -z "$(ip -6 route show 2001:db8:2::/64)"', timeout: 30)
      machine.all_succeed(
        'osctl ct del --prune stalled',
        'osctl ct stop sibling',
        'osctl ct del --prune sibling',
      )

      # The -rn helper also owns static bridge addresses and default routes.
      # A DHCP client is intentionally absent from the documented contract.
      machine.all_succeed(
        'ip -6 address add fd00:618::1/64 dev lxcbr0',
        'osctl ct new --distribution alpine bridged',
        'osctl ct unset start-menu bridged',
        'osctl ct netif new bridge --link lxcbr0 --no-dhcp --gateway-v4 192.168.1.1 --gateway-v6 fd00:618::1 bridged eth0',
        'osctl ct netif ip add bridged eth0 192.168.1.70/24',
        'osctl ct netif ip add bridged eth0 fd00:618::70/64',
        'osctl ct mount bridged',
      )
      bridge_host_links = machine.succeeds('ls -1 /sys/class/net')[1].lines.map(&:strip).sort
      _, bridge_snapshot = machine.succeeds(
        %q{osctl ct exec -rn bridged sh -ec 'echo IPV4; ip -4 addr show dev eth0; echo IPV6; ip -6 addr show dev eth0; echo ROUTE4; ip -4 route show default; echo ROUTE6; ip -6 route show default; ping -c 1 -W 2 192.168.1.1; ping -6 -c 1 -W 2 fd00:618::1; echo END'}
      )
      expect(bridge_snapshot).to include('inet 192.168.1.70/24')
      expect(bridge_snapshot).to include('inet6 fd00:618::70/64')
      expect(bridge_snapshot).to match(/ROUTE4\ndefault via 192\.168\.1\.1 dev eth0\b/)
      expect(bridge_snapshot).to match(/ROUTE6\ndefault via fd00:618::1 dev eth0\b/)
      expect(bridge_snapshot).to include('END')
      machine.wait_until_succeeds('test "$(osctl ct show -H -o state bridged)" = stopped', timeout: 60)
      bridged_state = machine.osctl_json('ct show bridged')
      expect(bridged_state.fetch('init_pid')).to be_nil
      expect(bridged_state.fetch('recovery_tainted')).to be(false)
      expect(machine.succeeds('ls -1 /sys/class/net')[1].lines.map(&:strip).sort).to eq(bridge_host_links)
      machine.all_succeed(
        'osctl ct del --prune bridged',
        'ip -6 address del fd00:618::1/64 dev lxcbr0',
      )

      # Row 23: transient -n configures static networking only when an
      # interface exists. A container with no netifs must still run a
      # bounded helper, expose no configured guest interface or default
      # route and leave no host veth or stale daemon state. The kernel may
      # create inert tunnel devices in every network namespace. DHCP is not
      # part of this CLI contract.
      machine.all_succeed(
        'osctl ct new --distribution alpine isolated',
        'osctl ct unset start-menu isolated',
        'osctl ct mount isolated',
      )
      expect(machine.osctl_json('ct netif ls isolated')).to eq([])
      host_links = machine.succeeds('ip -o link show')[1]
      2.times do
        # A failed guest predicate otherwise reports only the generic osctl
        # exec exit code, hiding which interface or route leaked into -n.
        _, net_snapshot = machine.succeeds(
          %q{osctl ct exec -rn isolated sh -c 'echo IFACES; ls -1 /sys/class/net; echo IFACES_STATUS:$?; echo IPV4_DEFAULT; ip route show default; echo IPV4_STATUS:$?; echo IPV6_DEFAULT; ip -6 route show default; echo IPV6_STATUS:$?; echo LINKS; ip link show; echo END'}
        )
        iface_match = net_snapshot.match(/\AIFACES\n(.*?)IFACES_STATUS:0\n/m)
        expect(iface_match).not_to be_nil
        ifaces = iface_match[1].lines.map(&:strip)
        expect(ifaces).to include('lo')
        # These down tunnel endpoints are created by the supported kernel,
        # not by osctl. Reject any other interface, including a leaked veth.
        expect(ifaces - %w[lo erspan0 gre0 gretap0 ip6tnl0 tunl0]).to eq([])
        expect(net_snapshot).to match(/\nIPV4_DEFAULT\nIPV4_STATUS:0\nIPV6_DEFAULT\nIPV6_STATUS:0\nLINKS\n/)
        link_lines = net_snapshot.split("\nLINKS\n", 2).last.lines.grep(/^\d+: /)
        expect(link_lines.length).to eq(ifaces.length)
        expect(link_lines.reject { |line| line.match?(/^\d+: lo:/) || line.match?(/\bstate DOWN\b/) }).to eq([])
        machine.wait_until_succeeds('test "$(osctl ct show -H -o state isolated)" = stopped', timeout: 60)
        info = machine.osctl_json('ct show isolated')
        expect(info.fetch('init_pid')).to be_nil
        expect(info.fetch('recovery_tainted')).to be(false)
        expect(machine.succeeds('ip -o link show')[1]).to eq(host_links)
      end
      machine.succeeds('osctl ct del --prune isolated')

      # A real bridge disappears after configuration but before LXC startup.
      # Exercise the kernel network-setup error, not a substituted helper or
      # protocol fault, then repair the same interface and retry normally.
      machine.all_succeed(
        'test ! -e /sys/class/net/v618miss0',
        'ip link add name v618miss0 type bridge',
        'osctl ct new --distribution alpine netfault',
        'osctl ct unset start-menu netfault',
        'osctl ct netif new bridge --link v618miss0 --no-dhcp netfault eth0',
        'osctl ct mount netfault',
        'ip link del v618miss0',
      )
      netfault_rootfs = Shellwords.escape(machine.osctl_json('ct show netfault').fetch('rootfs'))
      netfault_host_links = machine.succeeds('ls -1 /sys/class/net')[1]
      ['exec -rn netfault touch /root/netlink-unexpected', 'runscript -rn netfault /root/transient-failure-payload'].each do |operation|
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        status, output = machine.execute("timeout 90 osctl ct #{operation}", timeout: 100)
        expect(status).not_to eq(0)
        expect([124, 137]).not_to include(status)
        expect(output).to include('error:')
        expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 90
        machine.wait_until_succeeds('test "$(timeout 30 osctl ct show -H -o state netfault)" = stopped', timeout: 60)
        info = machine.osctl_json('ct show netfault')
        expect(info.fetch('init_pid')).to be_nil
        expect(info.fetch('recovery_tainted')).to be(false)
        machine.wait_until_succeeds("! ps -eo args= | grep -E '^osctld: tank:netfault runner:'", timeout: 30)
        machine.all_succeed(
          "test ! -e #{netfault_rootfs}/root/netlink-unexpected",
          "test ! -e #{netfault_rootfs}/root/unexpected-payload",
        )
        expect(machine.succeeds('ls -1 /sys/class/net')[1]).to eq(netfault_host_links)
      end
      machine.all_succeed(
        'ip link add name v618miss0 type bridge',
        "osctl ct exec -rn netfault sh -c 'echo netlink-retry > /root/netlink-retry'",
        'osctl ct runscript -rn netfault /root/transient-failure-payload',
        "grep -Fx netlink-retry #{netfault_rootfs}/root/netlink-retry",
        "grep -Fx must-not-run #{netfault_rootfs}/root/unexpected-payload",
        'osctl ct start netfault',
        'osctl ct exec netfault grep -Fx netlink-retry /root/netlink-retry',
        'osctl ct stop netfault',
        'osctl ct del --prune netfault',
        'ip link del v618miss0',
      )
      expect(machine.succeeds('ls -1 /sys/class/net')[1]).to eq(netfault_host_links)
    '';
  }
)
