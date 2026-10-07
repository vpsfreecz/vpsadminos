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
        # Use the catalog kernel with host-controlled NFS cancellation.
        boot.kernelVersion = "6.12.95";
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

      def diagnose_remote_lock_precondition(version)
        require 'shellwords'

        # Project inside the guest before ShellLog receives any tool output.
        common = <<~'BASH'
          set -u
          set -o pipefail
          export LC_ALL=C
          records=
          rows=0
          unknown=0
          fail_capture() {
            printf 'NFS_LOCK_DIAGNOSTIC block=%s outcome=%s\n' "$block" "$1"
            exit 1
          }
          add() {
            rows=$((rows + 1))
            (( rows <= 15 )) || fail_capture truncated
            printf -v records '%s%s\n' "$records" "$*"
            bytes=$(printf %s "$records" | wc -c) || fail_capture unavailable
            (( bytes <= 8000 )) || fail_capture truncated
          }
          process_identity() {
            awk -v expected="$2" '
              NR != 1 { bad=1 }
              NR == 1 {
                if ($1 != expected) { bad=1; next }
                sub(/^[0-9]+ \(.*\) /, "")
                if (NF < 20 || $1 !~ /^[RSDZTtWXxKPI]$/ ||
                    $2 !~ /^[0-9]{1,10}$/ || $20 !~ /^[0-9]{1,20}$/) {
                  bad=1; next
                }
                value=expected " " $2 " " $20 " " $1
              }
              END { if (bad || NR != 1 || value == "") exit 1; print value }
            ' "$1"
          }
          namespace_id() {
            readlink "$1" | awk '
              NR == 1 && /^[a-z]+:\[[0-9]{1,20}\]$/ {
                sub(/^[a-z]+:\[/, ""); sub(/\]$/, ""); value=$0; next
              }
              { bad=1 }
              END { if (bad || NR != 1 || value == "") exit 1; print value }
            '
          }
          identities() {
            for ct in nfs1 nfs2; do
              value=$(osctl ct show -H -o state,init_pid "$ct") || return 1
              read -r state init extra <<< "$value"
              [[ "$state" == running && "$init" =~ ^[1-9][0-9]{0,9}$ &&
                 -z "$extra" ]] || return 1
              value=$(process_identity "/proc/$init/stat" "$init") || return 1
              read -r ignored ppid start state <<< "$value"
              pidns=$(namespace_id "/proc/$init/ns/pid") || return 1
              mntns=$(namespace_id "/proc/$init/ns/mnt") || return 1
              view="/proc/$init/root/proc"
              [[ "$(stat -f -c %T "$view")" == proc ]] || return 1
              value=$(process_identity "$view/1/stat" 1) || return 1
              read -r ignored ignored local_start ignored <<< "$value"
              [[ "$local_start" == "$start" ]] || return 1
              [[ "$(namespace_id "$view/1/ns/pid")" == "$pidns" ]] || return 1
              printf '%s %s %s %s %s\n' "$ct" "$init" "$start" "$pidns" "$mntns"
            done
          }
          file_tuple() {
            stat -c '%Hd:%Ld:%i:%F' "$1" | awk -F: '
              NR != 1 { bad=1 }
              NR == 1 {
                if (NF != 4 || $1 !~ /^[0-9]{1,10}$/ ||
                    $2 !~ /^[0-9]{1,10}$/ || $3 !~ /^[0-9]{1,20}$/) {
                  bad=1; next
                }
                kind=($4 == "regular file" || $4 == "regular empty file" ? "regular" : ($4 == "fifo" ? "fifo" : "other"))
                value=$1 " " $2 " " $3 " " kind
              }
              END { if (bad || NR != 1 || value == "") exit 1; print value }
            '
          }
          before=$(identities) || fail_capture unavailable
          while read -r ct init start pidns mntns; do
            add "identity ct=$ct state=running init=$init start=$start pidns=$pidns mntns=$mntns"
          done <<< "$before"
        BASH

        projections = {
          identity: <<~'BASH',
            while read -r ct init start pidns mntns; do
              [[ "$ct" == nfs2 ]] || continue
              for label in held control; do
                case "$label" in
                  held) path="/proc/$init/root/root/nfs-lock-held" ;;
                  control) path="/proc/$init/root/root/nfs-lock-control" ;;
                esac
                value=$(file_tuple "$path") || fail_capture unavailable
                read -r major minor inode kind <<< "$value"
                add "readiness ct=nfs2 path=$label type=$kind major=$major minor=$minor inode=$inode"
              done
            done <<< "$before"
          BASH
          mounts: <<~'BASH',
            while read -r ct init start pidns mntns; do
              value=$(awk -v selected="$protocol" '
                $5 == "/mnt/nfs" {
                  count++
                  if (split($0, halves, " - ") != 2) { bad=1; next }
                  split(halves[2], tail, " ")
                  if ($1 !~ /^[0-9]{1,10}$/ || $3 !~ /^[0-9]{1,10}:[0-9]{1,10}$/ ||
                      tail[1] !~ /^(nfs|nfs4)$/) { bad=1; next }
                  vers="unavailable"; proto="unavailable"; local_lock="unset"
                  hard=0; soft=0; softerr=0
                  n=split($6 "," tail[3], options, ",")
                  for (i=1; i<=n; i++) {
                    if (options[i] ~ /^vers=(3|4|4\.0|4\.1|4\.2)$/) vers=substr(options[i],6)
                    else if (options[i] ~ /^proto=(tcp|udp)$/) proto=substr(options[i],7)
                    else if (options[i] ~ /^local_lock=(none|all|flock|posix)$/)
                      local_lock=substr(options[i],12)
                    else if (options[i] == "hard") hard=1
                    else if (options[i] == "soft") soft=1
                    else if (options[i] == "softerr") softerr=1
                  }
                  if (vers == "unavailable" || proto == "unavailable") bad=1
                  value="mount id=" $1 " device=" $3 " type=" tail[1] \
                    " source_match=" (tail[2] == "10.0.0.10:/srv/nfs-cancellation") \
                    " root_match=" ($4 == "/") " vers=" vers " selected_match=" (vers == selected) \
                    " proto=" proto " hard=" hard " soft=" soft " softerr=" softerr \
                    " local_lock=" local_lock
                }
                END { if (bad || count != 1) exit 1; print value }
              ' "/proc/$init/mountinfo") || fail_capture unavailable
              add "$value ct=$ct"
              value=$(file_tuple "/proc/$init/root/mnt/nfs/cancel-lock") || fail_capture unavailable
              read -r major minor inode kind <<< "$value"
              add "file ct=$ct path=lock type=$kind major=$major minor=$minor inode=$inode"
            done <<< "$before"
            value=$(file_tuple /srv/nfs-cancellation/cancel-lock) || fail_capture unavailable
            read -r major minor inode kind <<< "$value"
            add "file ct=host path=backing type=$kind major=$major minor=$minor inode=$inode"
          BASH
          owners: <<~'BASH'
            lock_rows() {
              awk -v major="$2" -v minor="$3" -v inode="$4" '
                {
                  if ($1 == "lock:") { for(i=1;i<NF;i++) $i=$(i+1); NF-- }
                  if ($2 == "->") {
                    blocked=1
                    for(i=2;i<NF;i++) $i=$(i+1)
                    NF--
                  } else blocked=0
                  if (NF < 6 || split($6, device, ":") != 3) next
                  if (device[1] !~ /^[0-9a-fA-F]+$/ || device[2] !~ /^[0-9a-fA-F]+$/ ||
                      device[3] !~ /^[0-9]{1,20}$/) next
                  if (strtonum("0x" device[1]) != major ||
                      strtonum("0x" device[2]) != minor || "x" device[3] != "x" inode) next
                  count++
                  if (count > 16) { overflow=1; next }
                  if (NF != 8 || $2 !~ /^(POSIX|FLOCK)$/ || $3 != "ADVISORY" ||
                      $4 !~ /^(READ|WRITE)$/ || $5 !~ /^(-1|[1-9][0-9]{0,9})$/ ||
                      $7 !~ /^[0-9]{1,20}$/ || $8 !~ /^(EOF|[0-9]{1,20})$/) {
                    bad=1; next
                  }
                  result=result (blocked ? "blocked" : "granted") " " $2 " " $4 " " $5 " " $7 " " $8 "\n"
                }
                END {
                  if (overflow) exit 2
                  if (bad) exit 1
                  printf "%s",result
                }
              ' "$1"
            }
            observe_process() {
              local pid relation expected_parent first ignored parent started state digest wchan syscall
              local scanned matched fd_path fd value fd_major fd_minor fd_inode extra label info
              local info_inode mount fd_locks code grant kind mode holder range_start range_end
              pid="$1"
              relation="$2"
              expected_parent="$3"
              first=$(process_identity "$view/$pid/stat" "$pid") || fail_capture unavailable
              read -r ignored parent started state <<< "$first"
              [[ "$relation" != child || "$parent" == "$expected_parent" ]] || fail_capture changed
              digest=$(sha256sum "$view/$pid/exe" | awk '
                NR == 1 && $1 ~ /^[0-9a-f]{64}$/ { value=$1; next }
                { bad=1 }
                END { if (bad || NR != 1 || value == "") exit 1; print value }
              ') || fail_capture unavailable
              wchan=$(awk '
                NR == 1 && /^[A-Za-z0-9_]{1,64}$/ { value=$0; next }
                { bad=1 }
                END { if (bad || NR != 1 || value == "") exit 1; print value }
              ' "$view/$pid/wchan") || fail_capture unavailable
              syscall=$(awk '
                NR == 1 && $1 ~ /^(-1|[0-9]{1,10})$/ { value=$1; next }
                { bad=1 }
                END { if (bad || NR != 1 || value == "") exit 1; print value }
              ' "$view/$pid/syscall") || fail_capture unavailable
              add "process ct=$ct relation=$relation pid=$pid ppid=$parent start=$started state=$state exe_sha256=$digest wchan=$wchan syscall=$syscall"
              [[ -r "$view/$pid/fd" ]] || fail_capture unavailable
              scanned=0
              matched=0
              for fd_path in "$view/$pid/fd/"*; do
                [[ -L "$fd_path" ]] || continue
                scanned=$((scanned + 1))
                (( scanned <= 128 )) || fail_capture truncated
                fd=$(basename "$fd_path")
                [[ "$fd" =~ ^[0-9]{1,10}$ ]] || fail_capture unavailable
                value=$(stat -L -c '%Hd %Ld %i' "$fd_path") || fail_capture unavailable
                read -r fd_major fd_minor fd_inode extra <<< "$value"
                [[ "$fd_major" =~ ^[0-9]{1,10}$ && "$fd_minor" =~ ^[0-9]{1,10}$ &&
                   "$fd_inode" =~ ^[0-9]{1,20}$ && -z "$extra" ]] || fail_capture unavailable
                label=unmatched
                [[ "$fd_major $fd_minor $fd_inode" != "$lock_tuple" ]] || label=lock
                [[ "$fd_major $fd_minor $fd_inode" != "$control_tuple" ]] || label=control
                [[ "$label" != unmatched ]] || continue
                matched=$((matched + 1))
                info=$(awk '
                  /^ino:/ { if ($2 !~ /^[0-9]{1,20}$/ || ++inos != 1) bad=1; ino=$2 }
                  /^mnt_id:/ { if ($2 !~ /^[0-9]{1,10}$/ || ++mounts != 1) bad=1; mount=$2 }
                  END { if (bad || inos != 1 || mounts != 1) exit 1; print ino " " mount }
                ' "$view/$pid/fdinfo/$fd") || fail_capture unavailable
                read -r info_inode mount <<< "$info"
                [[ "$info_inode" == "$fd_inode" ]] || fail_capture changed
                [[ "$(stat -L -c '%Hd %Ld %i' "$fd_path")" == "$value" ]] || fail_capture changed
                add "descriptor ct=$ct pid=$pid fd=$fd path=$label inode=$fd_inode mount=$mount"
                fd_locks=$(lock_rows "$view/$pid/fdinfo/$fd" "$fd_major" "$fd_minor" "$fd_inode")
                code=$?
                (( code != 2 )) || fail_capture truncated
                (( code == 0 )) || fail_capture unavailable
                if [[ -n "$fd_locks" ]]; then
                  while read -r grant kind mode holder range_start range_end; do
                    add "fd_lock ct=$ct pid=$pid fd=$fd grant=$grant kind=$kind mode=$mode holder=$holder start=$range_start end=$range_end"
                  done <<< "$fd_locks"
                fi
              done
              add "descriptors ct=$ct pid=$pid matches=$matched reader_proof=unknown"
              [[ "$(process_identity "$view/$pid/stat" "$pid")" == "$first" ]] || fail_capture changed
              verified_process_identity="$first"
            }
            while read -r ct init start pidns mntns; do
              view="/proc/$init/root/proc"
              value=$(file_tuple "/proc/$init/root/mnt/nfs/cancel-lock") || fail_capture unavailable
              read -r major minor inode kind <<< "$value"
              [[ "$kind" == regular ]] || fail_capture unavailable
              lock_tuple="$major $minor $inode"
              control_tuple=unavailable
              if [[ "$ct" == nfs2 ]]; then
                value=$(file_tuple "/proc/$init/root/root/nfs-lock-control") || fail_capture unavailable
                read -r control_major control_minor control_inode control_kind <<< "$value"
                [[ "$control_kind" == fifo ]] || fail_capture unavailable
                control_tuple="$control_major $control_minor $control_inode"
              fi
              locks=$(lock_rows "$view/locks" "$major" "$minor" "$inode")
              code=$?
              (( code != 2 )) || fail_capture truncated
              (( code == 0 )) || fail_capture unavailable
              if [[ -z "$locks" ]]; then
                unknown=1
                add "owners ct=$ct observation=unknown matching_rows=0"
                continue
              fi
              while read -r grant kind mode holder range_start range_end; do
                add "lock ct=$ct grant=$grant kind=$kind mode=$mode pid=$holder start=$range_start end=$range_end major=$major minor=$minor inode=$inode"
                [[ "$holder" != -1 ]] || fail_capture unavailable
                observe_process "$holder" owner 0
                owner_identity="$verified_process_identity"
                [[ "$(process_identity "$view/$holder/stat" "$holder")" == "$owner_identity" ]] || fail_capture changed
                children=$(head -c 512 "$view/$holder/task/$holder/children") || fail_capture unavailable
                [[ "$(process_identity "$view/$holder/stat" "$holder")" == "$owner_identity" ]] || fail_capture changed
                bytes=$(printf %s "$children" | wc -c) || fail_capture unavailable
                (( bytes < 512 )) || fail_capture truncated
                for child in $children; do
                  [[ "$child" =~ ^[1-9][0-9]{0,9}$ ]] || fail_capture unavailable
                  [[ "$(process_identity "$view/$holder/stat" "$holder")" == "$owner_identity" ]] || fail_capture changed
                  observe_process "$child" child "$holder"
                  [[ "$(process_identity "$view/$holder/stat" "$holder")" == "$owner_identity" ]] || fail_capture changed
                done
                [[ "$(process_identity "$view/$holder/stat" "$holder")" == "$owner_identity" ]] || fail_capture changed
              done <<< "$locks"
              [[ "$(lock_rows "$view/locks" "$major" "$minor" "$inode")" == "$locks" ]] || fail_capture changed
              value=$(file_tuple "/proc/$init/root/mnt/nfs/cancel-lock") || fail_capture changed
              read -r major_after minor_after inode_after kind_after <<< "$value"
              [[ "$major_after $minor_after $inode_after" == "$lock_tuple" && "$kind_after" == regular ]] || fail_capture changed
              if [[ "$ct" == nfs2 ]]; then
                value=$(file_tuple "/proc/$init/root/root/nfs-lock-control") || fail_capture changed
                read -r major_after minor_after inode_after kind_after <<< "$value"
                [[ "$major_after $minor_after $inode_after" == "$control_tuple" && "$kind_after" == fifo ]] || fail_capture changed
              fi
            done <<< "$before"
          BASH
        }
        footer = <<~'BASH'
          after=$(identities) || fail_capture unavailable
          [[ "$before" == "$after" ]] || fail_capture changed
          outcome=usable
          (( unknown == 0 )) || outcome=unknown
          printf 'NFS_LOCK_DIAGNOSTIC block=%s outcome=%s\n%s' "$block" "$outcome" "$records"
          (( unknown == 0 ))
        BASH
        projections.each do |block, projection|
          script = "block=#{block}\nprotocol=#{version}\n#{common}#{projection}#{footer}"
          status, = machine.execute("#{['bash', '-c', script].shelljoin} 2>/dev/null", timeout: 15)
          warn "NFS_LOCK_DIAGNOSTIC phase=initial_remote_contention protocol=#{version} error=CommandSucceeded command_status=0 block=#{block} status=#{status}"
        rescue StandardError
          warn "NFS_LOCK_DIAGNOSTIC phase=initial_remote_contention block=#{block} outcome=exception remaining=unavailable"
          break
        end
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
            precondition_error = nil
            begin
              # Verify that this is a remotely contended lock, not local-only
              # flock emulation, before making the server unreachable.
              begin
                machine.fails("osctl ct exec nfs1 flock -n /mnt/nfs/cancel-lock true")
              rescue OsVm::CommandSucceeded => error
                precondition_error = error
                begin
                  diagnose_remote_lock_precondition(version)
                rescue StandardError
                  begin
                    warn "NFS_LOCK_DIAGNOSTIC phase=initial_remote_contention outcome=reporting_unavailable"
                  rescue StandardError
                    # Even a logger failure must preserve the initial exception.
                  end
                end
                raise
              end
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
              begin
                machine.succeeds("osctl ct exec nfs2 sh -c 'echo release > /root/nfs-lock-control'", timeout: 15)
              rescue StandardError => release_error
                raise unless precondition_error

                # The release is still attempted once; retain the earlier failure.
                secondary = case release_error
                            when OsVm::CommandFailed then 'CommandFailed'
                            when OsVm::TimeoutError then 'TimeoutError'
                            when OsVm::KernelFailure then 'KernelFailure'
                            when OsVm::MachineShellClosed then 'MachineShellClosed'
                            else 'StandardError'
                            end
                begin
                  warn "NFS_LOCK_DIAGNOSTIC release=unavailable secondary=#{secondary} primary=CommandSucceeded"
                rescue StandardError
                  # Preserve the primary if the bounded secondary log also fails.
                end
              end
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
            # Reset control paths retained from earlier protocol groups.
            expect(machine.succeeds("osctl ct show -H -o state nfs1")[1].strip).to eq('stopped')
            machine.succeeds(
              "rm -f #{rootfs}/root/nfs-init-ready " \
                "#{rootfs}/root/nfs-init-written #{rootfs}/root/nfs-init-control",
            )
            machine.all_succeed(
              "test ! -e #{rootfs}/root/nfs-init-ready",
              "test ! -e #{rootfs}/root/nfs-init-written",
              "test ! -e #{rootfs}/root/nfs-init-control",
            )
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
