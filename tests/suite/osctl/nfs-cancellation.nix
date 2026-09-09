import ../../make-test.nix (
  { pkgs }:
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
    name = "osctl-nfs-cancellation";
    description = ''
      Hard NFS retry, forced container teardown and client isolation
    '';
    tags = [ "ci" ];

    machine = import ../../machines/vpsadminos/with-tank.nix {
      inherit pkgs;
      config = {
        services.nfs.server.enable = true;
        osctl.exportfs.enable = true;
      };
    };

    testScript = ''
      before(:suite) do
        machine.start
        machine.wait_for_osctl_pool("tank")
        machine.wait_until_online

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

      def isolate_client(operation)
        machine.all_succeed(
          "iptables -#{operation} FORWARD -s 192.168.1.21 -d 10.0.0.10 -j DROP",
          "iptables -#{operation} FORWARD -s 10.0.0.10 -d 192.168.1.21 -j DROP",
        )
      end

      def mount_nfs(ct, version, path = '/mnt/nfs')
        machine.succeeds(
          "osctl ct exec #{ct} mount -t nfs " \
            "-o vers=#{version},proto=tcp,timeo=10,retrans=2 " \
            "10.0.0.10:/srv/nfs-cancellation #{path}",
        )
        # No explicit hard option: the default must no longer be overridden.
        options = machine.succeeds("osctl ct exec #{ct} cat /proc/mounts")[1]
          .lines.find { |line| line.split[1] == path }.split[3].split(',')
        expect(options).to include('hard')
        expect(options).not_to include('soft', 'softerr')
      end

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
        machine.succeeds("osctl ct stop #{options} nfs1", timeout: timeout)
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
            mount_nfs('nfs1', version)
            mount_nfs('nfs2', version)
          end

          it "retries an outage beyond soft timeout and preserves the payload" do
            isolate_client('I')
            begin
              start_writer(version)
              # timeo=10,retrans=2 would fail a soft RPC well before this.
              sleep(30)
              machine.fails("osctl ct exec nfs1 test -e /root/nfs-done")
              machine.succeeds("osctl ct exec nfs2 sh -c 'echo live > /mnt/nfs/other-client'")
            ensure
              isolate_client('D')
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
            ensure
              machine.succeeds("osctl ct exec nfs2 sh -c 'echo release > /root/nfs-lock-control'", timeout: 15)
            end
            machine.wait_until_succeeds("osctl ct exec nfs2 flock -n /mnt/nfs/cancel-lock true")
            machine.succeeds("osctl ct start nfs1", timeout: 60)
            mount_nfs('nfs1', version)
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
                  "nsenter --net=#{held_net} unshare --mount sh -c " \
                    "'mount --make-rslave /; mount -t sysfs sysfs /sys; " \
                    "cat /sys/fs/nfs/net/nfs_client/shutdown'",
                )[1].strip
                expect(state).to eq('1')
                # The child network namespace shares the root owner's
                # barrier without ever being discovered by a process scan.
                owner = "nsenter --net=#{held_net} unshare --mount sh -c"
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
            control = "nsenter -t #{init_pid} --net unshare --mount sh -c"
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
                  "nsenter --net=#{netns} unshare --mount sh -c " \
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

          after(:context) do
            %w[nfs1 nfs2].each do |ct|
              # Preserve the original failure if an example could not restart
              # its container; cleanup must not replace it with an exec error.
              next unless machine.succeeds("osctl ct show -H -o state #{ct}")[1].strip == 'running'

              machine.succeeds("osctl ct exec #{ct} umount /mnt/nfs")
            end
          end
        end
      end
    '';
  }
)
