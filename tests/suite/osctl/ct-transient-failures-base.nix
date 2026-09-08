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
        'osctl ct mount stalled',
        'osctl ct new --distribution alpine sibling',
        'osctl ct unset start-menu sibling',
        'osctl ct netif new routed sibling eth0',
        'osctl ct netif ip add sibling eth0 192.0.2.61/32',
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
          machine.succeeds("! ps -eo args= | grep -E '^osctld: tank:stalled runner:'")
          expect(machine.osctl_json('ct show sibling').fetch('init_pid')).to eq(sibling_init)
          expect(machine.succeeds('ip -o address show dev lo')[1]).to eq(host_loopback)
          machine.all_succeed(
            'osctl ct exec sibling grep -Fx sibling-data /root/retained',
            'ping -c 1 192.0.2.61',
          )
        end
      end

      # A failed transient run must release locks/state for both another
      # transient payload and ordinary guest startup without a daemon restart.
      machine.all_succeed(
        "echo normal > #{rootfs}/transient-mode",
        'osctl ct exec -rn stalled ping -c 1 255.255.255.254',
        'osctl ct runscript -rn stalled /root/transient-failure-payload',
        "grep -Fx must-not-run #{rootfs}/root/unexpected-payload",
        'osctl ct start stalled',
      )
      machine.wait_until_succeeds('osctl ct exec stalled rc-service networking status')
      machine.wait_until_succeeds('ping -c 1 192.0.2.60')
      machine.all_succeed(
        'osctl ct stop stalled',
        'osctl ct del --prune stalled',
        'osctl ct stop sibling',
        'osctl ct del --prune sibling',
      )
    '';
  }
)
