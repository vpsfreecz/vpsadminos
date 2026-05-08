let
  network = [
    { type = "user"; }
    { type = "socket"; }
  ];

  serverAddress = "192.168.10.12";
  crasherAddress = "192.168.10.11";
  exportPath = "/storage/vpsfree.cz/crashdump";
in
import ../../make-test.nix (
  { pkgs }:
  {
    name = "crashdump-nfs-inspect";

    description = ''
      Test that the crash initrd can mount a ZFS sharenfs NFSv4 export and
      upload dmesg plus crash inspection data
    '';

    tags = [ "ci" ];

    machines = {
      server =
        import ../../machines/vpsadminos/with-tank.nix {
          inherit pkgs;
          config =
            { ... }:
            {
              networking.hostName = "server";
              networking.custom = ''
                ip addr add ${serverAddress}/24 dev eth1
                ip link set eth1 up
              '';

              services.nfs.server = {
                enable = true;
                nfsd.port = 2049;
                mountdPort = 20048;
                statdPort = 662;
                lockdPort = 32769;
              };

              networking.firewall.allowedTCPPorts = [
                111
                662
                2049
                20048
                32769
              ];
              networking.firewall.allowedUDPPorts = [
                111
                662
                2049
                20048
                32769
              ];

              boot.zfs.pools.tank.datasets."vpsfree.cz/crashdump".properties = {
                mountpoint = exportPath;
                sharenfs = "rw=${crasherAddress}/32,no_root_squash";
              };
            };
        }
        // {
          networks = network;
        };

      crasher =
        import ../../machines/vpsadminos/with-empty.nix {
          inherit pkgs;
          config =
            { ... }:
            {
              networking.hostName = "crasher";
              networking.custom = ''
                ip addr add ${crasherAddress}/24 dev eth1
                ip link set eth1 up
              '';

              boot.initrd = {
                kernelModules = [
                  "lockd"
                  "netfs"
                  "nfs"
                  "nfsv4"
                  "sunrpc"
                ];

                network = {
                  enable = true;
                  useDHCP = false;
                  setClock = false;
                  customSetupCommands = ''
                    if grep -q this_is_a_crash_kernel /proc/cmdline ; then
                      echo "Configuring crashdump NFS test network"
                      ip addr add ${crasherAddress}/24 dev eth1
                      ip link set eth1 up
                    fi
                  '';
                };

                extraUtilsCommands = ''
                  copy_bin_and_libs ${pkgs.nfs-utils}/bin/mount.nfs
                '';
              };

              boot.crashDump = {
                enable = true;
                inspect.enable = true;
                kernelParams = [ "console=ttyS0" ];
                commands = ''
                  date=$(date +%Y%m%dT%H%M%S)
                  mountpoint="/mnt/crashdump"
                  target="$mountpoint/crasher/$date"
                  server="${serverAddress}:${exportPath}"

                  echo "Crash initrd NFS upload test"
                  echo "open files limit: $(ulimit -n)"

                  if [ -e /proc/vmcore ] ; then
                    ls -l /proc/vmcore
                  else
                    echo "/proc/vmcore is missing"
                  fi

                  mkdir -p "$mountpoint"

                  echo "Mounting NFS"
                  mount.nfs -v -o vers=4 "$server" "$mountpoint" \
                    || fail "Unable to mount NFS share"

                  echo "Target dir $target"
                  mkdir -p "$target"

                  echo "Saving metadata"
                  uname -r > "$target/kernel-version"
                  cat /proc/cmdline > "$target/cmdline"

                  echo "Dumping dmesg"
                  makedumpfile --dump-dmesg /proc/vmcore "$target/dmesg"
                  rc=$?
                  echo "makedumpfile exited with $rc"
                  [ "$rc" = 0 ] || fail "Unable to dump dmesg"

                  echo "Collecting crash inspection data"
                  mkdir -p "$target/inspect"
                  if crash-collect "$target/inspect"; then
                    echo 0 > "$target/inspect.exit-status"
                    echo "crash-collect exited with 0"
                  else
                    rc=$?
                    echo "$rc" > "$target/inspect.exit-status"
                    echo "crash-collect failed with $rc"
                    fail "Unable to collect crash inspection data"
                  fi

                  echo "Syncing filesystems"
                  sync

                  echo "Rebooting"
                  reboot -f
                '';
              };
            };
        }
        // {
          networks = network;
        };
    };

    testScript = ''
      require 'shellwords'

      SERVER_ADDRESS = '${serverAddress}'
      CRASHER_ADDRESS = '${crasherAddress}'
      EXPORT_PATH = '${exportPath}'

      message = 'hello crash kernel nfs inspect test'

      def self.latest_crash_dir
        _, path = server.succeeds(
          "find #{Shellwords.escape(EXPORT_PATH)}/crasher -mindepth 1 -maxdepth 1 -type d | sort | tail -n 1"
        )
        path.strip
      end

      def self.wait_for_uploaded_crash
        server.wait_until_succeeds(<<~CMD, timeout: 180)
          target=$(find #{Shellwords.escape(EXPORT_PATH)}/crasher -mindepth 1 -maxdepth 1 -type d | sort | tail -n 1)
          test -n "$target"
          test -s "$target/dmesg"
          test -f "$target/kernel-version"
          test -f "$target/cmdline"
          test -f "$target/inspect.exit-status"
          test -f "$target/inspect/status"
          test -f "$target/inspect/manifest"
          test -f "$target/inspect/ps-active.txt"
          test -f "$target/inspect/bt-active.txt"
        CMD
      end

      server.start
      server.wait_for_osctl_pool('tank')
      server.wait_for_service('nfsd')
      server.wait_until_succeeds("test -d #{Shellwords.escape(EXPORT_PATH)}", timeout: 60)
      server.succeeds('zfs share -a', timeout: 60)
      server.wait_until_succeeds(
        "exportfs -v | tr '\\n\\t' '  ' | grep -F #{Shellwords.escape(EXPORT_PATH)} | grep -F #{Shellwords.escape(CRASHER_ADDRESS)}",
        timeout: 60
      )

      crasher.start
      crasher.wait_for_service('crashdump')

      server.wait_until_succeeds("ping -c 1 #{CRASHER_ADDRESS}", timeout: 60)
      crasher.wait_until_succeeds("ping -c 1 #{SERVER_ADDRESS}", timeout: 60)

      crasher.succeeds("mkdir -p /mnt/host-nfs-check")
      crasher.succeeds(
        "mount.nfs -v -o vers=4 #{SERVER_ADDRESS}:#{Shellwords.escape(EXPORT_PATH)} /mnt/host-nfs-check",
        timeout: 60
      )
      crasher.succeeds("printf '%s\n' host-stage > /mnt/host-nfs-check/host-stage.txt")
      crasher.succeeds("umount /mnt/host-nfs-check")
      expect(server.succeeds("cat #{Shellwords.escape(EXPORT_PATH)}/host-stage.txt")[1].strip)
        .to eq('host-stage')

      _, loaded = crasher.succeeds('cat /sys/kernel/kexec_crash_loaded')
      expect(loaded.strip).to eq('1')

      crasher.execute("echo #{Shellwords.escape(message)} > /dev/kmsg")

      begin
        crasher.execute('echo c > /proc/sysrq-trigger')
      rescue OsVm::MachineShellClosed
      else
        fail 'Expected machine shell to be closed'
      end

      wait_for_uploaded_crash
      target = latest_crash_dir
      expect(target).not_to eq("")

      expect(server.succeeds("cat #{Shellwords.escape(target)}/inspect.exit-status")[1].strip)
        .to eq('0')
      server.succeeds("grep -F #{Shellwords.escape(message)} #{Shellwords.escape(target)}/dmesg")
      server.succeeds("grep -F 'vmcore=/proc/vmcore' #{Shellwords.escape(target)}/inspect/manifest")
      server.succeeds("grep -F 'ps-active.txt 0' #{Shellwords.escape(target)}/inspect/status")
      server.succeeds("grep -F 'bt-active.txt 0' #{Shellwords.escape(target)}/inspect/status")
    '';
  }
)
