{
  pkgs,
  machine,
  name,
  description,
  baseline ? false,
}:
let
  dirtyInitProgram = pkgs.pkgsStatic.stdenv.mkDerivation {
    name = "nfs-dirty-init";
    src = ./nfs-cancellation;
    dontConfigure = true;
    buildPhase = ''
      "$CC" -std=gnu11 -O2 -Wall -Wextra -Werror -o dirty-init dirty-init.c
    '';
    installPhase = ''
      install -Dm755 dirty-init "$out/bin/dirty-init"
    '';
  };
  dirtyInit = pkgs.writeScript "nfs-dirty-init.sh" ''
    #!/bin/sh
    set -eu
    export PATH=/usr/sbin:/usr/bin:/sbin:/bin
    ip link set lo up
    ip link set eth0 up
    ip addr replace 192.168.1.21/24 dev eth0
    ip route replace default via 192.168.1.1 dev eth0
    mkdir -p /mnt/nfs
    rm -f /root/nfs-init-ready /root/nfs-init-written /root/nfs-init-control
    mount -t nfs -o "vers=$1,proto=tcp,timeo=10,retrans=2,nolock" \
      10.0.0.10:/srv/nfs-cancellation /mnt/nfs
    exec /sbin/nfs-dirty-init-program "/mnt/nfs/dirty-init-$1"
  '';
in
{
  inherit name description;
  tags =
    if baseline then
      [ "livepatch-amd" ]
    else
      [
        "ci"
        # Keep both unchanged NFS groups within the existing 350-minute steps.
        # Native NFS follows representative-v6 on the same intel-kvm class;
        # the main Intel row retains cumulative .95 NFS coverage.
        (
          if name == "osctl-nfs-cancellation-native110" then
            "livepatch-qualification-intel-representative-v6"
          else
            "livepatch-intel"
        )
      ];
  inherit machine;

  testScript = ''
    before(:suite) do
      machine.start
      machine.wait_for_osctl_pool("tank")
      machine.wait_until_online
      # A port-selected gateway MAC makes stopping one container disrupt the
      # other client's TCP connection, independently of NFS cancellation.
      @nfs_bridge_mac = machine.succeeds(
        'test "$(cat /sys/class/net/lxcbr0/addr_assign_type)" = 3 && ' \
          'cat /sys/class/net/lxcbr0/address',
      )[1].strip

      ${pkgs.lib.optionalString baseline ''
        assert_unpatched_baseline
      ''}

      %w[nfs1 nfs2].each_with_index do |ct, i|
        machine.all_succeed(
          "osctl ct new --distribution alpine #{ct}",
          "osctl ct unset start-menu #{ct}",
          "osctl ct netif new bridge --link lxcbr0 --no-dhcp #{ct} eth0",
          "osctl ct netif ip add #{ct} eth0 192.168.1.#{21 + i}/24",
          "osctl ct set dns-resolver #{ct} 1.1.1.1",
          "osctl ct start #{ct}",
        )
        container_apk(machine, ct, 'update', name: "Update APK indexes in #{ct}")
        container_apk(machine, ct, 'add', 'nfs-utils', 'iproute2', 'util-linux', name: "Install NFS utilities in #{ct}")
        machine.all_succeed(
          "osctl ct exec #{ct} rc-update add rpcbind default",
          "osctl ct exec #{ct} rc-update add rpc.statd default",
          "osctl ct exec #{ct} rc-service rpcbind start",
          "osctl ct exec #{ct} rc-service rpc.statd start",
          "osctl ct exec #{ct} mkdir -p /mnt/nfs /mnt/nfs-again",
        )
      end

      machine.all_succeed(
        "mkdir -p /srv/nfs-cancellation",
        "chmod 0777 /srv/nfs-cancellation",
        "osctl-exportfs server new --address 10.0.0.10 " \
          "--nfs-versions 3,4,4.0,4.1,4.2 server1",
        "osctl-exportfs export add --directory /srv/nfs-cancellation " \
          "--host 192.168.1.0/24 --options fsid=1234,rw,no_root_squash server1",
        "osctl-exportfs server start server1",
      )
      machine.wait_until_succeeds("test -s /run/osctl/exportfs/servers/server1/pid")
      # NFSD implies enabled 4.0 from +4; it only prints disabled -4.0.
      machine.wait_until_succeeds(
        "nsenter -t $(cat /run/osctl/exportfs/servers/server1/pid) -m -n " \
          "cat /proc/fs/nfsd/versions | grep -Fx '+3 +4 +4.1 +4.2'",
      )
    end

    def isolate_client(operation, reset: false)
      action = reset ? '-p tcp -j REJECT --reject-with tcp-reset' : '-j DROP'
      machine.all_succeed(
        "iptables -#{operation} FORWARD -s 192.168.1.21 -d 10.0.0.10 #{action}",
        "iptables -#{operation} FORWARD -s 10.0.0.10 -d 192.168.1.21 #{action}",
      )
    end

    def with_nfs_lock_trace
      trace = '/sys/kernel/tracing/instances/nfs_cancellation_lock'
      machine.succeeds('mountpoint -q /sys/kernel/tracing || mount -t tracefs tracefs /sys/kernel/tracing')
      machine.succeeds("mkdir #{trace}")
      completed = false
      begin
        # Retain the holder, delegation recall and contender in one bounded
        # per-CPU ring. This observes the unchanged lock assertions below.
        machine.all_succeed(
          "echo 1024 > #{trace}/buffer_size_kb",
          "echo global > #{trace}/trace_clock",
        )
        %w[nfs4 nfsd sunrpc filelock].each do |group|
          machine.succeeds("echo 1 > #{trace}/events/#{group}/enable")
        end
        machine.succeeds("echo 1 > #{trace}/tracing_on")
        yield trace
        completed = true
      ensure
        # Try every cleanup operation. Preserve an original test/setup error,
        # but a successful body must not hide failed trace cleanup.
        cleanup_error = nil
        [
          "echo 0 > #{trace}/tracing_on",
          "echo 0 > #{trace}/events/enable",
          "rmdir #{trace}",
        ].each do |command|
          begin
            machine.succeeds(command, timeout: 15)
          rescue StandardError => e
            cleanup_error ||= e
            warn "NFS lock trace cleanup failed: #{e.message}"
          end
        end
        raise cleanup_error if completed && cleanup_error
      end
    end

    def mount_nfs(ct, version, path = '/mnt/nfs')
      machine.succeeds(
        "osctl ct exec #{ct} mount -t nfs " \
          "-o vers=#{version},proto=tcp,timeo=10,retrans=2 " \
          "10.0.0.10:/srv/nfs-cancellation #{path}",
      )
      # Do not request soft: only the unpatched container policy forces it.
      options = machine.succeeds("osctl ct exec #{ct} cat /proc/mounts")[1]
        .lines.find { |line| line.split[1] == path }.split[3].split(',')
      expect(options).to include('${if baseline then "soft" else "hard"}')
      expect(options).not_to include('${if baseline then "hard" else "soft"}', 'softerr')
    end

    ${pkgs.lib.optionalString baseline ''
      def assert_unpatched_baseline
        puts 'VULNERABLE BASELINE: frozen .95, no livepatch; not a v7 target pass'
        machine.all_succeed(
          'test "$(uname -r)" = 6.12.95',
          'test -d /sys/kernel/livepatch',
          'test -z "$(find /sys/kernel/livepatch -mindepth 1 -maxdepth 1 -print -quit)"',
          'test -z "$(find /sys/module -maxdepth 1 -name "livepatch_[0-9]*" -print -quit)"',
          'uname -a; cat /proc/modules; ls -la /sys/kernel/livepatch',
        )
      end

      def baseline_writer_diagnostics
        # Capture the blocked syscall/socket before restoring the route. Mount
        # flags alone do not show which operation exhausted the test deadline.
        [
          "osctl ct exec nfs1 sh -c 'cat /root/nfs-writer.log; cat /root/nfs-done'",
          "ps -eLo pid,tid,ppid,stat,wchan:32,comm,args",
          "for p in $(pgrep -x dd); do echo WRITER:$p; " \
            "cat /proc/$p/syscall /proc/$p/wchan /proc/$p/stack; ls -l /proc/$p/fd; done",
          "osctl ct exec nfs1 ss -ntoi",
          "dmesg | tail -n 100",
        ].each do |command|
          begin
            machine.execute(command, timeout: 15)
          rescue StandardError => e
            warn "Baseline diagnostic failed: #{command}: #{e.message}"
          end
        end
      end
    ''}

    def start_writer(version, path = '/mnt/nfs')
      machine.all_succeed(
        "osctl ct exec nfs1 sh -c 'rm -f /root/nfs-done /root/nfs-started; " \
          "dd if=/dev/urandom of=/root/nfs-payload bs=1M count=16'",
        "osctl ct exec nfs1 sh -c \"nohup sh -c 'touch /root/nfs-started; " \
          "dd if=/root/nfs-payload of=#{path}/payload-#{version} bs=1M conv=fsync; " \
          "echo \\\$? > /root/nfs-done' >/root/nfs-writer.log 2>&1 </dev/null &\"",
      )
      machine.wait_until_succeeds("osctl ct exec nfs1 test -e /root/nfs-started")
    end

    def stop_nfs_client(options = '--kill', timeout: 60)
      result = machine.succeeds("osctl ct stop #{options} nfs1", timeout: timeout)
      expect(machine.succeeds('cat /sys/class/net/lxcbr0/address')[1].strip).to eq(@nfs_bridge_mac)
      result
    rescue StandardError
      # Keep diagnostics in the native command log before the caller restores
      # connectivity, and never replace the original stop failure.
      [
        "tail -n 250 /var/log/osctld",
        "ps -eLo pid,tid,ppid,stat,wchan:32,comm,args",
        "for p in $(ps -eo pid=,stat= | awk '$2 ~ /^D/ {print $1}'); do " \
          "echo STACK:$p; cat /proc/$p/stack; done",
        "dmesg | tail -n 100",
      ].each do |command|
        begin
          machine.execute(command, timeout: 15)
        rescue StandardError
          next
        end
      end
      raise
    end

    %w[3 4.0 4.1 4.2].each do |version|
      describe "NFS #{version}", order: :defined do
        before(:context) do
          # The callback may still use an older connection than the forechannel.
          # Retain transport history from before either client's first mount,
          # not just from the later lock/delegation-recall operation.
          transport_trace = '/sys/kernel/tracing/instances/nfs_cancellation_transport'
          machine.succeeds('mountpoint -q /sys/kernel/tracing || mount -t tracefs tracefs /sys/kernel/tracing')
          machine.all_succeed(
            "mkdir #{transport_trace}",
            "echo 1024 > #{transport_trace}/buffer_size_kb",
            "echo global > #{transport_trace}/trace_clock",
          )
          %w[sock/inet_sock_set_state tcp/tcp_receive_reset].each do |event|
            machine.all_succeed(
              "echo 'sport == 2049 || dport == 2049' > #{transport_trace}/events/#{event}/filter",
              "echo 1 > #{transport_trace}/events/#{event}/enable",
            )
          end
          # Send-reset stores packed socket addresses, not scalar port fields.
          # Keep those records unfiltered in the same bounded instance.
          machine.succeeds("echo 1 > #{transport_trace}/events/tcp/tcp_send_reset/enable")
          machine.succeeds("echo 1 > #{transport_trace}/tracing_on")
          mount_nfs('nfs1', version)
          mount_nfs('nfs2', version)
        end

  ''
  + (
    if baseline then
      ''
        it "observes forced soft retry and absent cancellation controls without v7" do
          assert_unpatched_baseline
          init_pid = Integer(machine.succeeds("osctl ct show -H -o init_pid nfs1")[1].strip)
          machine.succeeds("test \"$(readlink /proc/#{init_pid}/ns/user)\" != \"$(readlink /proc/1/ns/user)\"")
          # The outer driver shell's errexit does not apply inside this shell.
          control = "nsenter -t #{init_pid} --net unshare --mount sh -ec"
          machine.succeeds(
            "#{control} 'mount --make-rslave /; mount -t sysfs sysfs /sys; " \
              "test -d /sys/fs/nfs/net/nfs_client; " \
              "test ! -e /sys/fs/nfs/net/nfs_client/shutdown; " \
              "test ! -e /sys/fs/nfs/net/nfs_client/shutdown_tree; " \
              "find /sys/fs/nfs -maxdepth 5 -print'",
          )
          # NFSv4 soft RPCs suppress retransmission timeouts while TCP remains
          # connected. Break the transport rather than merely blackholing it;
          # use the same fault in the target's hard-retry/payload example.
          isolate_client('I', reset: true)
          begin
            start_writer(version)
            # The old forced-soft policy must fail I/O, unlike the target's
            # continuing hard retry. A timeout is a failed control, not PASS.
            machine.wait_until_succeeds("osctl ct exec nfs1 test -e /root/nfs-done", timeout: 90)
            status = Integer(machine.succeeds("osctl ct exec nfs1 cat /root/nfs-done")[1].strip)
            expect(status).to be > 0
            output = machine.succeeds("osctl ct exec nfs1 cat /root/nfs-writer.log")[1]
            expect(output).to match(/Input\/output error|I\/O error/)
            machine.succeeds("osctl ct exec nfs2 sh -c 'echo live > /mnt/nfs/other-client'")
          rescue StandardError, RSpec::Expectations::ExpectationNotMetError
            baseline_writer_diagnostics
            raise
          ensure
            isolate_client('D', reset: true)
          end
          machine.succeeds("osctl ct exec nfs1 sh -c 'echo recovered > /mnt/nfs/recovered-#{version}'")
          expect(machine.succeeds("cat /srv/nfs-cancellation/recovered-#{version}")[1].strip).to eq('recovered')
          assert_unpatched_baseline
        end
      ''
    else
      ''
        it "retries an outage beyond soft timeout and preserves the payload" do
          isolate_client('I', reset: true)
          begin
            start_writer(version)
            # The baseline proves soft I/O fails with this broken transport;
            # a TCP blackhole alone does not bound NFSv4 soft RPC retries.
            sleep(30)
            machine.fails("osctl ct exec nfs1 test -e /root/nfs-done")
            machine.succeeds("osctl ct exec nfs2 sh -c 'echo live > /mnt/nfs/other-client'")
          ensure
            isolate_client('D', reset: true)
          end
          machine.wait_until_succeeds("osctl ct exec nfs1 test -e /root/nfs-done", timeout: 120)
          expect(machine.succeeds("osctl ct exec nfs1 cat /root/nfs-done")[1].strip).to eq('0')
          machine.succeeds("osctl ct exec nfs1 cmp /root/nfs-payload /mnt/nfs/payload-#{version}")
          local_hash = machine.succeeds("osctl ct exec nfs1 sha256sum /root/nfs-payload")[1].split.first
          server_hash = machine.succeeds("sha256sum /srv/nfs-cancellation/payload-#{version}")[1].split.first
          expect(server_hash).to eq(local_hash)
        end

        it "cancels shared mounts on forced stop without cancelling another container" do
          mount_nfs('nfs1', version, '/mnt/nfs-again')
          isolate_client('I')
          begin
            start_writer(version)
            sleep(5)
            machine.fails("osctl ct exec nfs1 test -e /root/nfs-done")
            stop_nfs_client
            expect(machine.succeeds("osctl ct show -H -o state nfs1")[1].strip).to eq('stopped')
            machine.succeeds("osctl ct exec nfs2 sh -c 'echo survived > /mnt/nfs/other-client'")
          ensure
            isolate_client('D')
          end

          machine.succeeds("osctl ct start nfs1", timeout: 60)
          mount_nfs('nfs1', version)
          machine.succeeds("osctl ct exec nfs1 sh -c 'echo restarted > /mnt/nfs/restarted'")
          expect(machine.succeeds("osctl ct exec nfs2 cat /mnt/nfs/restarted")[1].strip).to eq('restarted')
        end

        it "cancels a mount already blocked inside the kernel" do
          machine.succeeds("osctl ct exec nfs1 umount /mnt/nfs")
          init_pid = Integer(machine.succeeds("osctl ct show -H -o init_pid nfs1")[1].strip)
          # Leave rpcbind/mountd reachable for v3, but blackhole the NFS
          # protocol itself. Require a mount syscall stack below so a
          # userspace mount helper retry cannot satisfy this test.
          rules = [
            "FORWARD -s 192.168.1.21 -d 10.0.0.10 -p tcp --dport 2049 -j DROP",
            "FORWARD -s 10.0.0.10 -d 192.168.1.21 -p tcp --sport 2049 -j DROP",
          ]
          rules.each { |rule| machine.succeeds("iptables -I #{rule}") }
          begin
            machine.succeeds(
              "osctl ct exec nfs1 sh -c 'nohup mount -t nfs " \
                "-o vers=#{version},proto=tcp,port=2049,timeo=10,retrans=2,nolock " \
                "10.0.0.10:/srv/nfs-cancellation /mnt/nfs " \
                ">/root/nfs-mount.log 2>&1 </dev/null &'",
            )
            machine.wait_until_succeeds(
              "p=$(osctl ct exec nfs1 pidof mount.nfs); test -n \"$p\" && " \
                "grep -E '(__x64_sys_mount|__do_sys_mount|do_mount)' " \
                "/proc/#{init_pid}/root/proc/$p/stack",
              timeout: 30,
            )
            stop_nfs_client
            expect(machine.succeeds("osctl ct show -H -o state nfs1")[1].strip).to eq('stopped')
            machine.succeeds("osctl ct exec nfs2 sh -c 'echo mount-survived > /mnt/nfs/other-client'")
          ensure
            rules.each { |rule| machine.succeeds("iptables -D #{rule}") }
          end
          machine.succeeds("osctl ct start nfs1", timeout: 60)
          mount_nfs('nfs1', version)
        end

        it "bounds graceful shutdown with forced fallback during an outage" do
          isolate_client('I')
          begin
            start_writer(version)
            sleep(5)
            machine.fails("osctl ct exec nfs1 test -e /root/nfs-done")
            stop_nfs_client('--timeout 5', timeout: 90)
            expect(machine.succeeds("osctl ct show -H -o state nfs1")[1].strip).to eq('stopped')
            machine.succeeds("osctl ct exec nfs2 sh -c 'echo graceful-survived > /mnt/nfs/other-client'")
          ensure
            isolate_client('D')
          end
          machine.succeeds("osctl ct start nfs1", timeout: 60)
          mount_nfs('nfs1', version)
        end

        it "cancels a remote lock waiter without releasing another container's lock" do
          with_nfs_lock_trace do |trace|
            machine.succeeds(
              "osctl ct exec nfs2 sh -c \"rm -f /root/nfs-lock-held /root/nfs-lock-control; " \
                "mkfifo /root/nfs-lock-control; " \
                "nohup flock -x /mnt/nfs/cancel-lock sh -c " \
                "'touch /root/nfs-lock-held; read ignored < /root/nfs-lock-control' " \
                ">/root/nfs-lock.log 2>&1 </dev/null &\"",
            )
            machine.wait_until_succeeds("osctl ct exec nfs2 test -e /root/nfs-lock-held")
            begin
              # Verify that this is a remotely contended lock, not local-only
              # flock emulation, before making the server unreachable.
              machine.fails("osctl ct exec nfs1 flock -n /mnt/nfs/cancel-lock true")
              machine.succeeds(
                "osctl ct exec nfs1 sh -c 'rm -f /root/nfs-lock-acquired; " \
                  "nohup flock -x /mnt/nfs/cancel-lock touch /root/nfs-lock-acquired " \
                  ">/root/nfs-lock.log 2>&1 </dev/null &'",
              )
              sleep(5)
              machine.fails("osctl ct exec nfs1 test -e /root/nfs-lock-acquired")
              isolate_client('I')
              begin
                stop_nfs_client
                expect(machine.succeeds("osctl ct show -H -o state nfs1")[1].strip).to eq('stopped')
                machine.fails("osctl ct exec nfs2 flock -n /mnt/nfs/cancel-lock true")
                machine.succeeds("osctl ct exec nfs2 sh -c 'echo lock-survived > /mnt/nfs/other-client'")
              ensure
                isolate_client('D')
              end
            rescue StandardError, RSpec::Expectations::ExpectationNotMetError
              # Preserve lock-owner and NFS state before releasing the holder's
              # FIFO. Suite-end diagnostics run after cleanup and miss it.
              # The server mounts proc in its own PID namespace. Enter it too,
              # so /proc/self/net resolves for nfsstat instead of returning ENOENT.
              nfs_server = "nsenter -t $(cat /run/osctl/exportfs/servers/server1/pid) -m -n -p"
              transport_trace = '/sys/kernel/tracing/instances/nfs_cancellation_transport'
              commands = [
                "echo 0 > #{trace}/tracing_on",
                "echo 0 > #{transport_trace}/tracing_on",
                "cat #{transport_trace}/per_cpu/cpu*/stats",
                "cat #{transport_trace}/trace",
                "cat #{trace}/per_cpu/cpu*/stats",
                "cat #{trace}/trace",
                "cat /proc/locks",
                'stat -Lc "path=%n dev=%d inode=%i links=%h" /srv/nfs-cancellation/cancel-lock',
                "#{nfs_server} sh -c '" \
                  "cat /proc/fs/nfsd/clients/*/info /proc/fs/nfsd/clients/*/states'",
                "#{nfs_server} nfsstat -s",
                "#{nfs_server} ss -ntoi",
                "iptables-save",
                "dmesg | tail -n 150",
              ]
              %w[nfs1 nfs2].each do |ct|
                commands << "osctl ct exec #{ct} sh -c '" \
                  "ps -ef; cat /root/nfs-lock.log; cat /proc/locks; " \
                  "for pid in $(pgrep -x flock); do " \
                  "echo NFS_LOCK_HOLDER pid=$pid; ls -l /proc/$pid/fd; " \
                  "for fd in /proc/$pid/fdinfo/*; do echo NFS_LOCK_FD $fd; cat \"$fd\"; done; " \
                  "stat -Lc \"path=%n dev=%d inode=%i links=%h\" /proc/$pid/fd/*; done; " \
                  "stat -Lc \"path=%n dev=%d inode=%i links=%h\" /mnt/nfs/cancel-lock; " \
                  "cat /proc/fs/nfsfs/servers /proc/fs/nfsfs/volumes; " \
                  "cat /proc/mounts; nfsstat -c; ss -ntoi'"
              end
              commands.each do |command|
                begin
                  machine.execute(command, timeout: 15)
                rescue StandardError
                  next
                end
              end
              raise
            ensure
              machine.succeeds("osctl ct exec nfs2 sh -c 'echo release > /root/nfs-lock-control'", timeout: 15)
            end
            machine.wait_until_succeeds("osctl ct exec nfs2 flock -n /mnt/nfs/cancel-lock true")
            machine.succeeds("osctl ct start nfs1", timeout: 60)
            mount_nfs('nfs1', version)
          end
        end

        it "cancels an NFS mount in a processless child network namespace" do
          held_net = "/run/nfs-child-#{version}"
          init_pid = Integer(machine.succeeds("osctl ct show -H -o init_pid nfs1")[1].strip)
          machine.all_succeed(
            "osctl ct exec nfs1 umount /mnt/nfs",
            "osctl ct exec nfs1 mkdir -p /mnt/nfs-child",
            "osctl ct exec nfs1 ip netns add nfstest",
            "osctl ct exec nfs1 ip link set eth0 netns nfstest",
            "osctl ct exec nfs1 ip -n nfstest link set lo up",
            "osctl ct exec nfs1 ip -n nfstest link set eth0 up",
            "osctl ct exec nfs1 ip -n nfstest addr replace 192.168.1.21/24 dev eth0",
            "osctl ct exec nfs1 ip -n nfstest route replace default via 192.168.1.1 dev eth0",
            "osctl ct exec nfs1 nsenter --net=/run/netns/nfstest mount -t nfs " \
              "-o vers=#{version},proto=tcp,timeo=10,retrans=2,nolock " \
              "10.0.0.10:/srv/nfs-cancellation /mnt/nfs-child",
            "osctl ct exec nfs1 sh -c 'echo child-live > /mnt/nfs-child/child-live; sync'",
            "touch #{held_net}",
            "mount --bind /proc/#{init_pid}/root/run/netns/nfstest #{held_net}",
          )
          begin
            # The host bind mount retains only a namespace reference, not
            # a process which the cancellation scanner could discover.
            expect(machine.succeeds("osctl ct exec nfs1 ip netns pids nfstest")[1].strip).to be_empty
            isolate_client('I')
            begin
              start_writer(version, '/mnt/nfs-child')
              sleep(5)
              machine.fails("osctl ct exec nfs1 test -e /root/nfs-done")
              stop_nfs_client
              expect(machine.succeeds("osctl ct show -H -o state nfs1")[1].strip).to eq('stopped')
              state = machine.succeeds(
                "nsenter --net=#{held_net} unshare --mount sh -ec " \
                  "'mount --make-rslave /; mount -t sysfs sysfs /sys; " \
                  "cat /sys/fs/nfs/net/nfs_client/shutdown'",
              )[1].strip
              expect(state).to eq('1')
              # The child network namespace shares the root owner's
              # barrier without ever being discovered by a process scan.
              owner = "nsenter --net=#{held_net} unshare --mount sh -ec"
              machine.succeeds(
                "#{owner} 'mount --make-rslave /; mount -t sysfs sysfs /sys; " \
                  "test \"$(cat /sys/fs/nfs/net/nfs_client/shutdown_tree)\" = 1'",
              )
              machine.succeeds("osctl ct exec nfs2 sh -c 'echo child-survived > /mnt/nfs/other-client'")
            ensure
              isolate_client('D')
            end
          ensure
            machine.succeeds("umount #{held_net}; rm -f #{held_net}")
          end
          machine.succeeds("osctl ct start nfs1", timeout: 60)
          mount_nfs('nfs1', version)
        end

        it "rejects new mounts and descendants after host terminal cancellation" do
          init_pid = Integer(machine.succeeds("osctl ct show -H -o init_pid nfs1")[1].strip)
          # Tenant root must not be able to set a host-owned terminal policy.
          machine.fails(
            "osctl ct exec nfs1 sh -c 'echo 1 > /sys/fs/nfs/net/nfs_client/shutdown_tree'",
          )
          control = "nsenter -t #{init_pid} --net unshare --mount sh -ec"
          machine.succeeds(
            "#{control} 'mount --make-rslave /; mount -t sysfs sysfs /sys; " \
              "test \"$(cat /sys/fs/nfs/net/nfs_client/shutdown_tree)\" = 0; " \
              "echo 1 > /sys/fs/nfs/net/nfs_client/shutdown_tree'",
          )
          # The server is online. Neither a fresh mount nor a repeat write
          # may reset the admission barrier in the existing namespace.
          mount_command = "osctl ct exec nfs1 mount -t nfs " \
            "-o vers=#{version},proto=tcp,timeo=10,retrans=2,nolock " \
            "10.0.0.10:/srv/nfs-cancellation /mnt/nfs-again"
          machine.fails(mount_command, timeout: 15)
          machine.succeeds(
            "#{control} 'mount --make-rslave /; mount -t sysfs sysfs /sys; " \
              "echo 1 > /sys/fs/nfs/net/nfs_client/shutdown_tree'",
          )
          machine.fails(
            "#{control} 'mount --make-rslave /; mount -t sysfs sysfs /sys; " \
              "echo 0 > /sys/fs/nfs/net/nfs_client/shutdown_tree'",
          )
          machine.all_succeed(
            "osctl ct exec nfs1 ip netns add afterabort",
            "osctl ct exec nfs1 sh -c \"rm -f /root/nfs-after-pid; " \
              "nohup unshare --user --map-root-user --net sh -c " \
              "'echo \\\$\\\$ > /root/nfs-after-pid; exec sleep 300' " \
              ">/root/nfs-after.log 2>&1 </dev/null &\"",
          )
          begin
            machine.wait_until_succeeds("osctl ct exec nfs1 test -s /root/nfs-after-pid", timeout: 30)
            child_pid = Integer(machine.succeeds("osctl ct exec nfs1 cat /root/nfs-after-pid")[1].strip)
            # Both a new netns owned by the original userns and one owned
            # by a newly created child userns must inherit cancellation.
            [
              "/proc/#{init_pid}/root/run/netns/afterabort",
              "/proc/#{init_pid}/root/proc/#{child_pid}/ns/net",
            ].each do |netns|
              state = machine.succeeds(
                "nsenter --net=#{netns} unshare --mount sh -ec " \
                  "'mount --make-rslave /; mount -t sysfs sysfs /sys; " \
                  "cat /sys/fs/nfs/net/nfs_client/shutdown " \
                  "/sys/fs/nfs/net/nfs_client/shutdown_tree'",
              )[1].split
              expect(state).to eq(%w[1 1])
            end
            machine.succeeds("osctl ct exec nfs2 sh -c 'echo admission-survived > /mnt/nfs/other-client'")
          ensure
            stop_nfs_client
          end
          machine.succeeds("osctl ct start nfs1", timeout: 60)
          mount_nfs('nfs1', version)
        end

        it "recaptures cancellation handles after osctld restarts" do
          isolate_client('I')
          begin
            start_writer(version)
            sleep(5)
            machine.fails("osctl ct exec nfs1 test -e /root/nfs-done")
            machine.succeeds("sv -w 60 restart osctld", timeout: 90)
            machine.wait_for_service('osctld')
            machine.wait_for_osctl_pool('tank')
            stop_nfs_client
            expect(machine.succeeds("osctl ct show -H -o state nfs1")[1].strip).to eq('stopped')
            machine.succeeds("osctl ct exec nfs2 sh -c 'echo daemon-restart > /mnt/nfs/other-client'")
          ensure
            isolate_client('D')
          end
          machine.succeeds("osctl ct start nfs1", timeout: 60)
          mount_nfs('nfs1', version)
        end

        it "finishes unexpected init exit while NFS is unreachable" do
          isolate_client('I')
          begin
            start_writer(version)
            sleep(5)
            machine.fails("osctl ct exec nfs1 test -e /root/nfs-done")
            init_pid = Integer(machine.succeeds("osctl ct show -H -o init_pid nfs1")[1].strip)
            machine.succeeds("kill -KILL #{init_pid}")
            machine.wait_until_succeeds(
              "test \"$(osctl ct show -H -o state nfs1)\" = stopped",
              timeout: 60,
            )
            machine.succeeds("osctl ct exec nfs2 sh -c 'echo init-exit > /mnt/nfs/other-client'")
          ensure
            isolate_client('D')
          end
          machine.succeeds("osctl ct start nfs1", timeout: 60)
          mount_nfs('nfs1', version)
        end

        it "finishes PID1 exit with its own dirty NFS file descriptor" do
          machine.all_succeed(
            "osctl ct stop --kill nfs1",
            "osctl ct mount nfs1",
          )
          rootfs = machine.succeeds("osctl ct show -H -o rootfs nfs1")[1].strip
          machine.push_file("${dirtyInit}", File.join(rootfs, 'sbin/nfs-dirty-init'), preserve: true)
          machine.push_file(
            "${dirtyInitProgram}/bin/dirty-init",
            File.join(rootfs, 'sbin/nfs-dirty-init-program'),
            preserve: true,
          )
          machine.succeeds("osctl ct set init-cmd nfs1 /sbin/nfs-dirty-init #{version}")
          begin
            machine.succeeds("osctl ct start nfs1", timeout: 60)
            machine.wait_until_succeeds("test -e #{rootfs}/root/nfs-init-ready", timeout: 60)
            isolate_client('I')
            begin
              machine.succeeds("printf d > #{rootfs}/root/nfs-init-control")
              machine.wait_until_succeeds("test -e #{rootfs}/root/nfs-init-written", timeout: 60)
              machine.succeeds("printf e > #{rootfs}/root/nfs-init-control")
              machine.wait_until_succeeds(
                "test \"$(osctl ct show -H -o state nfs1)\" = stopped",
                timeout: 60,
              )
              machine.succeeds("osctl ct exec nfs2 sh -c 'echo dirty-init > /mnt/nfs/other-client'")
            ensure
              isolate_client('D')
            end
          ensure
            machine.succeeds("osctl ct unset init-cmd nfs1")
          end
          machine.succeeds("osctl ct start nfs1", timeout: 60)
          mount_nfs('nfs1', version)
        end

        it "host cancellation controls are root-only with exact modes" do
          init_pid = Integer(machine.succeeds("osctl ct show -H -o init_pid nfs1")[1].strip)
          # Fail on setup and intermediate assertions, not just the last command.
          control = "nsenter -t #{init_pid} --net unshare --mount sh -ec"

          modes = machine.succeeds(
            "osctl ct exec nfs1 stat -c '%a' " \
              "/sys/fs/nfs/net/nfs_client/shutdown " \
              "/sys/fs/nfs/net/nfs_client/shutdown_tree",
          )[1].split
          expect(modes).to eq(%w[600 600])

          # Tenant access is a permission failure, never a missing control.
          tenant = machine.succeeds(
            "osctl ct exec nfs1 sh -c " \
              "'cat /sys/fs/nfs/net/nfs_client/shutdown >/dev/null; echo rc=$?'",
          )[1].strip
          expect(tenant).to end_with('rc=1')
          machine.fails(
            "osctl ct exec nfs1 sh -c " \
              "'echo 1 > /sys/fs/nfs/net/nfs_client/shutdown'",
          )

          # Exactly one per-server control, mode 644, tenant-readable but not
          # tenant-writable.
          server_modes = machine.succeeds(
            "osctl ct exec nfs1 sh -c " \
              "'find /sys/fs/nfs -maxdepth 2 -name shutdown -not -path \"*/net/*\" " \
              "-exec stat -c %a {} +'",
          )[1].split
          expect(server_modes).not_to be_empty
          expect(server_modes.uniq).to eq(%w[644])
          machine.succeeds(
            "osctl ct exec nfs1 sh -c " \
              "'f=$(find /sys/fs/nfs -maxdepth 2 -name shutdown -not -path \"*/net/*\" " \
              "| head -n1); cat \"$f\" >/dev/null'",
          )
          machine.fails(
            "osctl ct exec nfs1 sh -c " \
              "'f=$(find /sys/fs/nfs -maxdepth 2 -name shutdown -not -path \"*/net/*\" " \
              "| head -n1); echo 1 > \"$f\"'",
          )

          # Host-side control works and flips the terminal state.
          machine.succeeds(
            "#{control} 'mount --make-rslave /; mount -t sysfs sysfs /sys; " \
              "test \"$(cat /sys/fs/nfs/net/nfs_client/shutdown)\" = 0; " \
              "echo 1 > /sys/fs/nfs/net/nfs_client/shutdown; " \
              "test \"$(cat /sys/fs/nfs/net/nfs_client/shutdown)\" = 1'",
          )
          dmesg = machine.succeeds("dmesg | grep -E 'NFS:.*(sysfs|cancellation)' || true")[1]
          expect(dmesg.strip).to eq("")
        ensure
          begin
            stop_nfs_client
          rescue StandardError
            nil
          end
          machine.succeeds("osctl ct start nfs1", timeout: 60)
          mount_nfs('nfs1', version)
        end

        it "drains every superblock of a shared client in one terminal action" do
          mount_nfs('nfs1', version, '/mnt/nfs-again')
          isolate_client('I')
          begin
            start_writer(version)
            sleep(5)
            machine.fails("osctl ct exec nfs1 test -e /root/nfs-done")
            stop_nfs_client
            expect(machine.succeeds("osctl ct show -H -o state nfs1")[1].strip).to eq('stopped')
            machine.succeeds("osctl ct exec nfs2 sh -c 'echo shared-survived > /mnt/nfs/other-client'")
          ensure
            isolate_client('D')
          end
          machine.succeeds("osctl ct start nfs1", timeout: 60)
          mount_nfs('nfs1', version)
          expect(machine.succeeds("osctl ct exec nfs2 cat /mnt/nfs/other-client")[1].strip).to eq('shared-survived')
        end

        it "rejects or safely joins a mount racing terminal cancellation" do
          machine.succeeds("osctl ct exec nfs1 umount /mnt/nfs")
          init_pid = Integer(machine.succeeds("osctl ct show -H -o init_pid nfs1")[1].strip)
          control = "nsenter -t #{init_pid} --net unshare --mount sh -ec"
          rules = [
            "FORWARD -s 192.168.1.21 -d 10.0.0.10 -p tcp --dport 2049 -j DROP",
            "FORWARD -s 10.0.0.10 -d 192.168.1.21 -p tcp --sport 2049 -j DROP",
          ]
          rules.each { |rule| machine.succeeds("iptables -I #{rule}") }
          begin
            machine.succeeds(
              "osctl ct exec nfs1 sh -c 'nohup mount -t nfs " \
                "-o vers=#{version},proto=tcp,port=2049,timeo=10,retrans=2,nolock " \
                "10.0.0.10:/srv/nfs-cancellation /mnt/nfs " \
                ">/root/nfs-mount.log 2>&1 </dev/null &'",
            )
            machine.wait_until_succeeds(
              "p=$(osctl ct exec nfs1 pidof mount.nfs); test -n \"$p\" && " \
                "grep -E '(__x64_sys_mount|__do_sys_mount|do_mount)' " \
                "/proc/#{init_pid}/root/proc/$p/stack",
              timeout: 30,
            )
            # Race the blocked mount with a host-side terminal write.
            machine.succeeds(
              "#{control} 'mount --make-rslave /; mount -t sysfs sysfs /sys; " \
                "echo 1 > /sys/fs/nfs/net/nfs_client/shutdown_tree'",
            )
            machine.wait_until_succeeds(
              "osctl ct exec nfs1 true && test -z \"$(osctl ct exec nfs1 pidof mount.nfs || true)\"",
              timeout: 60,
            )
            # Prove admission is closed independent of the test's own outage:
            # reachable network + fast refusal.
            rules.each { |rule| machine.succeeds("iptables -D #{rule} || true") }
            machine.fails(
              "osctl ct exec nfs1 mount -t nfs " \
                "-o vers=#{version},proto=tcp,timeo=10,retrans=2,nolock " \
                "10.0.0.10:/srv/nfs-cancellation /mnt/nfs-again",
              timeout: 15,
            )
            stop_nfs_client
            expect(machine.succeeds("osctl ct show -H -o state nfs1")[1].strip).to eq('stopped')
            machine.succeeds("osctl ct exec nfs2 sh -c 'echo race-survived > /mnt/nfs/other-client'")
          ensure
            rules.each { |rule| machine.succeeds("iptables -D #{rule} || true") }
          end
          machine.succeeds("osctl ct start nfs1", timeout: 60)
          mount_nfs('nfs1', version)
        end

        it "repeated terminal cancellation is idempotent" do
          init_pid = Integer(machine.succeeds("osctl ct show -H -o init_pid nfs1")[1].strip)
          control = "nsenter -t #{init_pid} --net unshare --mount sh -ec"
          machine.succeeds(
            "#{control} 'mount --make-rslave /; mount -t sysfs sysfs /sys; " \
              "echo 1 > /sys/fs/nfs/net/nfs_client/shutdown_tree'",
          )
          # A repeated write is a no-op success, the state is not reset and a
          # reset attempt stays rejected.
          machine.succeeds(
            "#{control} 'mount --make-rslave /; mount -t sysfs sysfs /sys; " \
              "echo 1 > /sys/fs/nfs/net/nfs_client/shutdown_tree; " \
              "test \"$(cat /sys/fs/nfs/net/nfs_client/shutdown_tree)\" = 1'",
          )
          machine.fails(
            "#{control} 'mount --make-rslave /; mount -t sysfs sysfs /sys; " \
              "echo 0 > /sys/fs/nfs/net/nfs_client/shutdown_tree'",
          )
          # An osctld restart over the already-cancelled container must not
          # undo the terminal state, and the stop must still complete.
          machine.succeeds("sv -w 60 restart osctld", timeout: 90)
          machine.wait_for_service('osctld')
          machine.wait_for_osctl_pool('tank')
          stop_nfs_client
          expect(machine.succeeds("osctl ct show -H -o state nfs1")[1].strip).to eq('stopped')
          machine.succeeds("osctl ct exec nfs2 sh -c 'echo idempotent-survived > /mnt/nfs/other-client'")
          machine.succeeds("osctl ct start nfs1", timeout: 60)
          mount_nfs('nfs1', version)
          # A fresh incarnation starts from a zero cancellation state.
          init_pid = Integer(machine.succeeds("osctl ct show -H -o init_pid nfs1")[1].strip)
          control = "nsenter -t #{init_pid} --net unshare --mount sh -ec"
          machine.succeeds(
            "#{control} 'mount --make-rslave /; mount -t sysfs sysfs /sys; " \
              "test \"$(cat /sys/fs/nfs/net/nfs_client/shutdown)\" = 0; " \
              "test \"$(cat /sys/fs/nfs/net/nfs_client/shutdown_tree)\" = 0'",
          )
        end

        it "container restart creates fresh NFS client state and a working mount" do
          isolate_client('I')
          begin
            start_writer(version)
            sleep(5)
            machine.fails("osctl ct exec nfs1 test -e /root/nfs-done")
            stop_nfs_client
            expect(machine.succeeds("osctl ct show -H -o state nfs1")[1].strip).to eq('stopped')
          ensure
            isolate_client('D')
          end
          machine.succeeds("osctl ct start nfs1", timeout: 60)
          mount_nfs('nfs1', version)
          init_pid = Integer(machine.succeeds("osctl ct show -H -o init_pid nfs1")[1].strip)
          control = "nsenter -t #{init_pid} --net unshare --mount sh -ec"
          machine.succeeds(
            "#{control} 'mount --make-rslave /; mount -t sysfs sysfs /sys; " \
              "test \"$(cat /sys/fs/nfs/net/nfs_client/shutdown)\" = 0; " \
              "test \"$(cat /sys/fs/nfs/net/nfs_client/shutdown_tree)\" = 0'",
          )
          start_writer(version)
          machine.wait_until_succeeds("osctl ct exec nfs1 test -e /root/nfs-done", timeout: 120)
          expect(machine.succeeds("osctl ct exec nfs1 cat /root/nfs-done")[1].strip).to eq('0')
          machine.succeeds("osctl ct exec nfs1 cmp /root/nfs-payload /mnt/nfs/payload-#{version}")
          machine.succeeds("osctl ct exec nfs1 sh -c 'flock -n /mnt/nfs/cancel-lock true'")
          machine.succeeds("osctl ct exec nfs1 pidof rpc.statd")
        end

        it "survives 25 forced stop/restart cycles with terminal cancellation" do
          25.times do |cycle|
            isolate_client('I')
            begin
              start_writer(version)
              sleep(5)
              machine.fails("osctl ct exec nfs1 test -e /root/nfs-done")
              stop_nfs_client
              expect(machine.succeeds("osctl ct show -H -o state nfs1")[1].strip).to eq('stopped')
            ensure
              isolate_client('D')
            end
            machine.succeeds("osctl ct start nfs1", timeout: 60)
            mount_nfs('nfs1', version)
            init_pid = Integer(machine.succeeds("osctl ct show -H -o init_pid nfs1")[1].strip)
            control = "nsenter -t #{init_pid} --net unshare --mount sh -ec"
            machine.succeeds(
              "#{control} 'mount --make-rslave /; mount -t sysfs sysfs /sys; " \
                "test \"$(cat /sys/fs/nfs/net/nfs_client/shutdown)\" = 0; " \
                "test \"$(cat /sys/fs/nfs/net/nfs_client/shutdown_tree)\" = 0'",
            )
            machine.succeeds(
              "osctl ct exec nfs1 sh -c 'echo cycle-#{cycle} > /mnt/nfs/cycle-#{cycle}'",
            )
          end
        end

      ''
  )
  + ''
        after(:context) do
          %w[nfs1 nfs2].each do |ct|
            # Preserve the original failure if an example could not restart
            # its container; cleanup must not replace it with an exec error.
            next unless machine.succeeds("osctl ct show -H -o state #{ct}")[1].strip == 'running'

            machine.succeeds("osctl ct exec #{ct} umount /mnt/nfs")
          end
          transport_trace = '/sys/kernel/tracing/instances/nfs_cancellation_transport'
          machine.all_succeed(
            "echo 0 > #{transport_trace}/tracing_on",
            "echo 0 > #{transport_trace}/events/enable",
            "rmdir #{transport_trace}",
          )
        end
      end
    end
  '';
}
