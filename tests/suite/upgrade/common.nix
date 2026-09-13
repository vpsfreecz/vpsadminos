# Shared native test; each named case pins its predecessor generations.
{
  name,
  revision,
  kernelPrefix,
  configuration ? null,
  activated ? null,
  # Whether the kernel the fixture boots preserves inherited proc subdirectory
  # mounts across a container mount namespace entry. The fixture machine boots
  # the *predecessor* revision's pinned kernel, not this checkout's, so this has
  # to be declared per pinned predecessor. False when that pin predates the
  # downstream kernfs-filter preservation fix; see the helper assertion below.
  kernelPreservesInheritedProcMounts ? false,
}:
args:
let
  previous = builtins.getFlake "github:vpsfreecz/vpsadminos/${revision}";
  current = builtins.getFlake (toString ../../..);
  system = args.system or builtins.currentSystem;
  cgroupVersion = args.cgroupVersion or 2;
  guestPolicies = args.guestPolicies or false;
  reverseActivation = args.reverseActivation or false;
  overlapActivation = args.overlapActivation or false;
  managementActivation = args.managementActivation or false;
  mountingActivation = args.mountingActivation or false;
  nestedDocker = args.nestedDocker or false;
  nestedPodman = args.nestedPodman or false;
  nestedIncus = args.nestedIncus or false;
  frozenActivation = args.frozenActivation or false;
  transferAcrossActivation = args.transferAcrossActivation or false;
  inheritedRecoveryTaint = args.inheritedRecoveryTaint or false;
  cgroupConfig.boot.enableUnifiedCgroupHierarchy = cgroupVersion == 2;
  activatedSource =
    if activated == null then
      null
    else
      builtins.getFlake "github:vpsfreecz/vpsadminos/${activated.revision}";
  activatedSystem =
    if activated == null then
      null
    else
      (activatedSource.lib.vpsadminosSystem {
        inherit system;
        configuration =
          if (activated.configuration or null) == null then
            null
          else
            import (activatedSource.outPath + "/${activated.configuration}");
        modules = [
          (activatedSource.outPath + "/tests/configs/vpsadminos/base.nix")
          (activatedSource.outPath + "/tests/configs/vpsadminos/pool-tank.nix")
          {
            disabledModules = [ (activatedSource.outPath + "/os/modules/osctl/test-shell.nix") ];
            imports = [ ../../../os/modules/osctl/test-shell.nix ];
            osctl.test-shell.shells = 1;
          }
          cgroupConfig
        ];
      }).config.system.build.toplevel;
  nextSystem =
    (current.lib.vpsadminosSystem {
      inherit system;
      configuration = args.configuration or null;
      modules = [
        ../../configs/vpsadminos/base.nix
        ../../configs/vpsadminos/pool-tank.nix
        { osctl.test-shell.shells = 1; }
        cgroupConfig
      ];
    }).config.system.build.toplevel;
in
import (previous.outPath + "/tests/make-test.nix")
  (
    { pkgs }:
    let
      resourceProbe = pkgs.pkgsStatic.stdenv.mkDerivation {
        name = "upgrade-resource-probe";
        dontUnpack = true;
        buildPhase = ''
          $CC -O2 -Wall -Wextra -Werror ${./resource-probe.c} -o resource-probe
        '';
        installPhase = ''
          install -Dm755 resource-probe $out/bin/resource-probe
        '';
      };

      workload = pkgs.writeScript "upgrade-workload" ''
        #!/bin/sh
        set -e
        trap 'exit 0' TERM INT HUP PWR
        # This fixture replaces Alpine init, so invoke the guest's generated
        # network configuration just as its normal boot would do.
        /sbin/ifup -a
        mkdir -p /upgrade
        echo retained-data > /upgrade/data
        (exec sleep 86400) &
        echo $! > /upgrade/worker.pid
        (exec /sbin/upgrade-busybox httpd -f -p 8080 -h /upgrade > /upgrade/http.log 2>&1) &
        echo $! > /upgrade/http.pid
        (exec /sbin/upgrade-busybox tcpsvd 0.0.0.0 8081 /sbin/upgrade-busybox cat > /upgrade/tcp.log 2>&1) &
        echo $! > /upgrade/tcp.pid
        echo UPGRADE_READY
        while IFS= read -r line; do
          printf 'UPGRADE_ECHO:%s\n' "$line"
        done
      '';

      stoppedNetwork = pkgs.writeScript "upgrade-stopped-network" ''
        #!/bin/sh
        set -eu
        ping -c 1 255.255.255.254
        grep -Fx predecessor-data /root/retained
        echo stopped-runscript-data > /root/stopped-runscript
      '';

      streamClient = pkgs.writeText "upgrade-tcp-stream.rb" ''
        require 'json'
        require 'socket'
        require 'timeout'

        address, prefix = ARGV
        socket = nil
        begin
          # Connect exactly once. Reconnection would hide an interrupted flow.
          socket = Socket.tcp(address, 8081, connect_timeout: 30)
          port = socket.local_address.ip_port
          sequence = 0
          until File.exist?("#{prefix}.stop")
            message = "#{sequence}\n"
            Timeout.timeout(30) do
              socket.write(message)
              raise 'sequence mismatch' unless socket.readline == message
            end
            sequence += 1
            File.write("#{prefix}.new", JSON.generate(sequence:, port:))
            File.rename("#{prefix}.new", "#{prefix}.progress")
            sleep(0.1)
          end
          File.write("#{prefix}.done", sequence.to_s)
        rescue StandardError => e
          File.write("#{prefix}.error", "#{e.class}: #{e.message}")
          raise
        ensure
          socket&.close
        end
      '';

      consoleClient = pkgs.writeText "upgrade-console.rb" ''
        require 'pty'
        require 'timeout'
        output = String.new
        PTY.spawn('osctl', 'ct', 'console', ARGV.fetch(0)) do |reader, writer, pid|
          begin
            Timeout.timeout(30) do
              output << reader.readpartial(4096) until output.include?('Press Ctrl+a q')
              writer.write("#{ARGV.fetch(1)}\n")
              output << reader.readpartial(4096) until output.include?("UPGRADE_ECHO:#{ARGV.fetch(1)}")
            end
            writer.write("\x01q")
            _, status = Timeout.timeout(10) { Process.wait2(pid) }
            raise "console failed: #{output}" unless status.success?
            puts output
          ensure
            unless status
              Process.kill('TERM', pid) rescue nil
              Process.wait(pid) rescue nil
            end
          end
        end
      '';
    in
    {
      name =
        "upgrade-${name}"
        + (if guestPolicies then "-guests" else "")
        + (if nestedDocker then "-nested-docker" else "")
        + (if nestedPodman then "-nested-podman" else "")
        + (if nestedIncus then "-nested-incus" else "")
        + (if frozenActivation then "-frozen" else "")
        + (if mountingActivation then "-pre-mount" else "")
        + (if cgroupVersion == 1 then "-v1" else "");
      description = "Switch from ${revision} to the current checkout on ${kernelPrefix}";
      tags = [
        "upgrade"
        "ci"
      ];

      machine = import (previous.outPath + "/tests/machines/vpsadminos/with-tank.nix") {
        inherit pkgs;
        config = {
          # Only the test transport follows the current runner. Boot the pinned
          # predecessor's real daemon, LXC, kernel, ZFS and system policy.
          disabledModules = [ (previous.outPath + "/os/modules/osctl/test-shell.nix") ];
          imports = [
            ../../../os/modules/osctl/test-shell.nix
            cgroupConfig
          ];
          system.extraDependencies = [
            nextSystem
          ]
          # Script store references are host dependencies, not guest roots.
          # Keep metadata tools in the predecessor across activation as well.
          ++ pkgs.lib.optionals transferAcrossActivation [
            pkgs.acl
            pkgs.attr
            pkgs.libcap
          ]
          ++ pkgs.lib.optionals overlapActivation [ pkgs.ruby ]
          ++ (if activatedSystem == null then [ ] else [ activatedSystem ]);
        };
      };

      testScript = ''
                require 'fileutils'
                require 'json'
                require 'shellwords'

                # Observe the predecessor's intermittent access denial without
                # ptrace, credential changes or a relaxed readiness assertion.
                def upgrade_access_trace_functions(machine)
                  cached = machine.instance_variable_get(:@upgrade_access_trace_functions)
                  return cached if cached

                  functions = %w[
                    cap_capget commit_creds_where auth_guard_current_where
                    auth_guard_task_check_status_where auth_guard_task_begin_transition_try_where
                    auth_guard_task_transition_open_where
                    kernfs_iop_permission kernfs_fop_open kernfs_fop_write_iter
                    security_inode_permission security_file_open security_file_permission
                    cgroup_file_open cgroup_file_write cgroup1_procs_write cgroup1_tasks_write
                    cgroup_procs_write cgroup_attach_task cgroup_migrate
                    cgroup_procs_write_start get_task_cred_checked_nowait_where
                  ]
                  # Same-TU wrappers can inline around their out-of-line probes.
                  # Discover only these enum-return helpers; optimized clones can
                  # change argument layouts, so probe their returns without args.
                  begin
                    status, output = machine.execute(<<~'SYMBOLS', timeout: 30)
                      awk '$2 ~ /^[tT]$/ && $3 ~ /^auth_guard_task_check_(result|reserved|owned_transition)([.](isra|constprop)[.][0-9]+)*$/ { print $3 }' /proc/kallsyms
                    SYMBOLS
                    symbols = output.lines.map(&:strip).uniq
                    valid = symbols.all? do |symbol|
                      symbol.match?(/\Aauth_guard_task_check_(?:result|reserved|owned_transition)(?:\.(?:isra|constprop)\.[0-9]+)*\z/)
                    end
                    if status == 0 && valid
                      warn "Upgrade access enum helper symbols: #{symbols.join(', ')}"
                      functions.concat(symbols)
                    else
                      warn 'Upgrade access enum helper discovery unavailable'
                    end
                  rescue StandardError => e
                    warn "Upgrade access enum helper discovery failed: #{e.class}: #{e.message}"
                  end
                  machine.instance_variable_set(:@upgrade_access_trace_functions, functions)
                end

                def start_upgrade_access_trace(machine)
                  root = machine.succeeds('mktemp -d /run/v618-upgrade-access.XXXXXX')[1].strip
                  unless root.match?(%r{\A/run/v618-upgrade-access\.[A-Za-z0-9]{6}\z})
                    raise "Unexpected trace directory: #{root.inspect}"
                  end
                  machine.instance_variable_set(:@upgrade_access_trace_root, root)
                  arguments = [root, *upgrade_access_trace_functions(machine)].shelljoin
                  status, output = machine.execute("bash -c #{<<~'TRACE'.shellescape} -- #{arguments}", timeout: 30)
                    set -eu
                    root=$1
                    shift
                    group=$(basename "$root" | tr '.-' '__')
                    mount -t tracefs none "$root"
                    instance=$root/instances/$group
                    errors=$root/instances/$group-errors
                    # Keep rare denial returns independent of noisy syscall/fork/helper records.
                    for path in "$instance" "$errors"; do
                      mkdir "$path"
                      echo 0 > "$path/tracing_on"
                      echo 1024 > "$path/buffer_size_kb"
                      echo mono > "$path/trace_clock"
                    done
                    for event in sys_enter_capget sys_exit_capget sys_enter_capset sys_exit_capset sys_enter_prctl sys_exit_prctl; do
                      echo 1 > "$instance/events/syscalls/$event/enable"
                    done
                    echo 1 > "$instance/events/sched/sched_process_fork/enable"
                    if test -e "$instance/events/seccomp/seccomp_filter/enable"; then
                      echo 1 > "$instance/events/seccomp/seccomp_filter/enable"
                    fi
                    for function; do
                      case "$function" in
                        kernfs_fop_write_iter|cgroup_file_write|cgroup1_procs_write|cgroup1_tasks_write|cgroup_procs_write|cgroup_procs_write_start|get_task_cred_checked_nowait_where)
                          type=s64 ;;
                        auth_guard_task_transition_open_where|auth_guard_current_where) type=u8 ;;
                        *) type=s32 ;;
                      esac
                      # Strings require dereferencing the saved entry argument.
                      context=""
                      case "$function" in
                        cap_capget|commit_creds_where) filter='result < 0' ;;
                        auth_guard_task_check_status_where|auth_guard_task_begin_transition_try_where)
                          # VALID is zero; retain BUSY and other refusal categories.
                          filter='result != 0'
                          context='context=+0($arg2):string' ;;
                        auth_guard_task_check_result*|auth_guard_task_check_reserved*|auth_guard_task_check_owned_transition*)
                          # No argument fetch from compiler-specialized helpers.
                          filter='result != 0' ;;
                        auth_guard_current_where)
                          filter='result == 0'
                          context='context=+0($arg1):string' ;;
                        auth_guard_task_transition_open_where)
                          # This predicate returns bool, not the check-result enum.
                          filter='result == 0'
                          context='context=+0($arg2):string' ;;
                        *) filter='result == -13 || result == -1' ;;
                      esac
                      # Dots in compiler symbol names are not valid event names.
                      event_name=$(printf '%s' "$function" | tr '.' '_')
                      # Store comm in the event, independent of saved-cmdline eviction.
                      if printf 'r:%s/%s %s result=$retval:%s task_comm=$comm %s\n' "$group" "$event_name" "$function" "$type" "$context" >> "$root/kprobe_events"; then
                        path=$errors
                        case "$function" in
                          auth_guard_task_check_result*|auth_guard_task_check_reserved*|auth_guard_task_check_owned_transition*)
                            # BUSY is also a normal helper fallback, not an outer denial.
                            path=$instance ;;
                        esac
                        event=$path/events/$group/$event_name
                        if ! echo "$filter" > "$event/filter"; then
                          echo "Return probe filter unavailable: $function"
                          continue
                        fi
                        # Compact helper history must not flood the rare-error buffer
                        # or unwind stacks for every normal owned-writer fallback.
                        if test "$path" = "$errors"; then
                          if ! printf 'stacktrace if %s\n' "$filter" > "$event/trigger"; then
                            echo "Return stack trace unavailable: $function"
                          fi
                        fi
                        if ! echo 1 > "$event/enable"; then
                          echo "Return probe enable failed: $function"
                        fi
                        if test "$function" = cgroup_file_open; then
                          # Mirror the outer denial into history and freeze only this
                          # private instance after its first EACCES record. Rare errors
                          # continue independently; later denials have no new history.
                          history_event=$instance/events/$group/$event_name
                          if ! { echo 'result == -13' > "$history_event/filter" &&
                            echo 'traceoff:1 if result == -13' > "$history_event/trigger" &&
                            echo 1 > "$history_event/enable"; }; then
                            echo 'Cgroup-open history freeze unavailable'
                          fi
                        fi
                      else
                        echo "Return probe unavailable: $function"
                        if test -r "$root/error_log"; then
                          echo 'Kernel trace error log:'
                          cat "$root/error_log" || true
                        fi
                      fi
                    done
                    echo 1 > "$errors/tracing_on"
                    echo 1 > "$instance/tracing_on"
                  TRACE
                  warn "Upgrade access trace setup failed (#{status}): #{output}" unless status == 0
                rescue StandardError => e
                  warn "Unable to start upgrade access trace: #{e.class}: #{e.message}"
                end

                def capture_upgrade_access_trace(machine)
                  root = machine.instance_variable_get(:@upgrade_access_trace_root)
                  return unless root

                  machine.instance_variable_set(:@upgrade_access_trace_root, nil)
                  arguments = [root, *upgrade_access_trace_functions(machine)].shelljoin
                  status, output = machine.execute("bash -c #{<<~'TRACE'.shellescape} -- #{arguments}", timeout: 30)
                    set +e
                    root=$1
                    shift
                    group=$(basename "$root" | tr '.-' '__')
                    # Freeze both streams before reading either or running diagnostics.
                    for instance in "$root/instances/$group" "$root/instances/$group-errors"; do
                      if test -d "$instance"; then
                        echo 0 > "$instance/tracing_on"
                      fi
                    done
                    {
                      date -Ins
                      uname -a
                      for instance in "$root/instances/$group" "$root/instances/$group-errors"; do
                        echo "--- instance: $instance ---"
                        if ! test -d "$instance"; then
                          echo 'Trace instance unavailable'
                          continue
                        fi
                        cat "$instance/trace_clock" "$instance/buffer_size_kb"
                        cat "$instance/trace"
                        for stats in "$instance"/per_cpu/cpu*/stats; do
                          echo "--- $stats ---"
                          cat "$stats"
                        done
                      done
                      for function; do
                        event_name=$(printf '%s' "$function" | tr '.' '_')
                        echo "--- return probe: $function ---"
                        # Include both routes, including the mirrored freeze event.
                        # The traceoff count records whether history stopped early.
                        for instance in "$root/instances/$group" "$root/instances/$group-errors"; do
                          event=$instance/events/$group/$event_name
                          echo "--- probe instance: $instance ---"
                          if test -d "$event"; then
                            cat "$event/format" "$event/filter" "$event/trigger" "$event/enable"
                          else
                            echo 'Return probe unavailable'
                          fi
                        done
                      done
                      cat "$root/kprobe_profile"
                    } > /run/osvm/shared-dir/upgrade-access-trace.log 2>&1
                    for instance in "$root/instances/$group" "$root/instances/$group-errors"; do
                      if ! test -d "$instance"; then continue; fi
                      echo 0 > "$instance/events/enable"
                      for function; do
                        event_name=$(printf '%s' "$function" | tr '.' '_')
                        trigger=$instance/events/$group/$event_name/trigger
                        if test -e "$trigger" && grep -q '^stacktrace' "$trigger"; then
                          echo '!stacktrace' > "$trigger"
                        fi
                        if test -e "$trigger" && grep -q '^traceoff' "$trigger"; then
                          echo '!traceoff' > "$trigger"
                        fi
                      done
                      rmdir "$instance"
                    done
                    for function; do
                      event_name=$(printf '%s' "$function" | tr '.' '_')
                      if test -d "$root/events/$group/$event_name"; then
                        printf -- '-:%s/%s\n' "$group" "$event_name" >> "$root/kprobe_events"
                      fi
                    done
                    if mountpoint -q "$root"; then umount "$root"; fi
                    rmdir "$root"
                  TRACE
                  warn "Upgrade access trace capture failed (#{status}): #{output}" unless status == 0
                  state_dir = File.dirname(machine.send(:console_log_path))
                  source = File.join(state_dir, 'shared-dir', 'upgrade-access-trace.log')
                  raise 'Upgrade access trace is not a regular file' unless File.lstat(source).file?

                  FileUtils.cp(source, File.join(state_dir, 'upgrade-access-trace.log'))
                rescue StandardError => e
                  warn "Unable to retain upgrade access trace: #{e.class}: #{e.message}"
                end

                def assert_guest_ready(machine, ctid)
                  command = "osctl ct exec #{Shellwords.escape(ctid)}"
                  begin
                    status, output = machine.execute("#{command} systemctl is-system-running --wait")
                  rescue StandardError
                    capture_upgrade_access_trace(machine)
                    raise
                  end
                  return if status == 0

                  # Freeze before further diagnostics can displace the failing
                  # syscalls and fork ancestry from the bounded trace buffer.
                  capture_upgrade_access_trace(machine)
                  # Retain the failing readiness state even if diagnostics fail.
                  details = [
                    'systemctl --failed --no-pager',
                    'journalctl -b -p err -n 80 --no-pager',
                    # Record access failures without changing the guest or its units.
                    "sh -c #{<<~'ACCESS'.shellescape}",
                      {
                        printf '\n--- guest access state ---\n'
                        id
                        printf '\n--- guest runtime versions ---\n'
                        uname -r
                        systemctl --version
                        if command -v rpm >/dev/null 2>&1; then
                          rpm -q systemd avahi libcap
                        elif command -v dpkg-query >/dev/null 2>&1; then
                          dpkg-query -W systemd avahi-daemon libcap2
                        fi
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
                            -p ControlGroup -p Slice -p Delegate -p PrivateUsers \
                            -p ProtectControlGroups -p DynamicUser \
                            -p CapabilityBoundingSet -p AmbientCapabilities -p SecureBits \
                            -p NoNewPrivileges -p SystemCallFilter -p SystemCallErrorNumber \
                            -p RestrictNamespaces -p FragmentPath -p DropInPaths -- "$unit")
                          printf '\n%s\n' "$properties"
                          # All priorities retain the startup stage preceding an error.
                          # Read only: do not retry, restart or clear the failed unit.
                          printf '\n--- failed unit journal: %s ---\n' "$unit"
                          journalctl -b -u "$unit" -n 80 --no-pager -o short-monotonic
                          cg=$(printf '%s\n' "$properties" | sed -n 's/^ControlGroup=//p')
                          # A failed unit may already have lost its cgroup. Keep
                          # that fact and label the slice-derived path explicitly.
                          slice=$(printf '%s\n' "$properties" | sed -n 's/^Slice=//p')
                          if test -z "$cg" && test -n "$slice"; then
                            parent=$(systemctl show --no-pager -p ControlGroup --value -- "$slice")
                            case "$parent" in
                              /*)
                                cg=$(printf '%s/%s' "$parent" "$unit" | sed 's,//,/,g')
                                printf 'InferredControlGroup=%s (from Slice; unit path may be absent)\n' "$cg"
                                ;;
                            esac
                          fi
                          # Include every visible hierarchy, including hybrid
                          # unified, and retain root metadata even without a path.
                          awk '$0 ~ / - cgroup2? / && $5 ~ /^\/sys\/fs\/cgroup(\/|$)/ { print $5 }' /proc/1/mountinfo |
                          head -n 16 | while IFS= read -r root; do
                            stat -Lc '%n %F %a %u:%g' "$root" "$root/cgroup.procs" "$root/tasks"
                            if test -n "$cg"; then
                              parent=$(dirname "$root$cg")
                              stat -Lc '%n %F %a %u:%g' "$root$cg" "$root$cg/cgroup.procs" \
                                "$root$cg/tasks" "$parent" "$parent/cgroup.procs" "$parent/tasks"
                            fi
                          done
                        done
                      } 2>&1 | head -c 65536
                    ACCESS
                  ].map do |diagnostic|
                    begin
                      machine.execute("#{command} #{diagnostic}", timeout: 30)[1]
                    rescue StandardError => e
                      "#{diagnostic}: #{e.class}: #{e.message}"
                    end
                  end
                  fail "guest #{ctid} readiness failed (#{status}): #{output}\n#{details.join("\n")}"
                end

                # Declared by the case that pins the predecessor generation: the machine boots
                # that predecessor's kernel, not this checkout's kernel.
                kernel_preserves_inherited_proc_mounts = ${
                  if kernelPreservesInheritedProcMounts then "true" else "false"
                }

                # Compare a container mount inventory with an earlier snapshot. Strict when the booted
                # kernel preserves inherited proc submounts. The predecessor's pinned kernel does not:
                # its kernfs-filter view invalidation detaches every submount below the invalidated
                # procfs dentry, so the only tolerated difference is the loss of mounts inside that
                # subtree. Nothing may be added, and nothing outside that subtree may disappear.
                expect_mounts_unchanged = lambda do |label, before, after|
                  if kernel_preserves_inherited_proc_mounts
                    expect(after).to eq(before), "#{label}:\n#{after}"
                  else
                    normalize = lambda { |text| text.gsub("//deleted", "") }
                    before_lines = normalize.call(before).lines.map(&:strip).reject(&:empty?)
                    after_lines = normalize.call(after).lines.map(&:strip).reject(&:empty?)
                    added = after_lines - before_lines
                    removed = before_lines - after_lines
                    expect(added).to eq([]), "#{label} added mounts:\n#{added.join("\n")}"
                    detached = lambda do |line|
                      mountpoint = line.split(' ')[4].to_s
                      fstype = line.split(' - ').last.to_s.split(' ').first.to_s
                      fstype == 'proc' || mountpoint.start_with?('/proc/')
                    end
                    unexpected = removed.reject { |line| detached.call(line) }
                    expect(unexpected).to eq([]), "#{label} removed mounts outside the kernel-detached proc subtree:\n#{unexpected.join("\n")}"
                    machine.succeeds(
                      "echo #{Shellwords.escape("#{label}: tolerated #{removed.size} kernel-detached mount(s)")}"
                    )
                  end
                end

                machine.start
                machine.wait_for_osctl_pool('tank')
                machine.wait_until_online
                expect(machine.succeeds("stat -f -c %T /sys/fs/cgroup")[1].strip).to eq('${
                  if cgroupVersion == 2 then "cgroup2fs" else "tmpfs"
                }')
                before_kernel = machine.succeeds('uname -r')[1].strip
                expect(before_kernel).to start_with('${kernelPrefix}')
                expect(machine.succeeds('readlink -f /run/current-system')[1].strip).not_to eq('${nextSystem}')
                before_boot = machine.succeeds('cat /proc/sys/kernel/random/boot_id')[1].strip
                booted_system = machine.succeeds('readlink -f /run/booted-system')[1].strip
                expect(machine.succeeds('readlink -f /run/current-system')[1].strip).to eq(booted_system)
                before_bpffs = machine.succeeds('stat -c %d:%i /sys/fs/bpf')[1].strip
                daemon_identity = lambda do
                  status = machine.succeeds('sv status osctld')[1]
                  supervisor = status.match(/\(pid (\d+)\)/).captures.first
                  # sv tracks the logging supervisor, not the daemon. Killing that
                  # supervisor leaves its child alive and creates a second daemon.
                  pids = machine.succeeds("pgrep -P #{supervisor} -f '^osctld: main$'")[1].split
                  expect(pids.length).to eq(1)
                  pid = pids.first
                  [pid, machine.succeeds("awk '{print $22}' /proc/#{pid}/stat")[1].strip]
                end
                machine.push_file('${consoleClient}', '/root/upgrade-console.rb')
                machine.push_file('${stoppedNetwork}', '/root/upgrade-stopped-network')
                machine.push_file('${streamClient}', '/root/upgrade-tcp-stream.rb')
                machine.succeeds('chmod 500 /root/upgrade-stopped-network')

                # A separate ordinary-init CT contains bounded OOM/fork workloads so
                # they cannot invalidate the two long-lived continuity workloads.
                cgroup_version = ${toString cgroupVersion}
                machine.all_succeed(
                  'osctl ct new --distribution alpine limited',
                  'osctl ct unset start-menu limited',
                  'osctl ct set cpu-limit limited 25',
                  'osctl ct set memory-limit limited 134217728 0',
                  "osctl ct cgparams set -v #{cgroup_version} limited pids.max 64",
                  "osctl ct cgparams set -v #{cgroup_version} limited cpuset.cpus 0",
                  'osctl ct devices chmod limited char 1 5 r',
                  'osctl ct mount limited',
                  'zfs create tank/upgrade-bind',
                  'echo inherited-bind > /tank/upgrade-bind/marker',
                  'osctl ct mounts new --fs /tank/upgrade-bind --type bind --opts bind,create=dir --mountpoint /mnt/inherited limited',
                )
                limited_root = machine.osctl_json('ct show limited').fetch('rootfs')
                machine.push_file('${resourceProbe}/bin/resource-probe', "#{limited_root}/bin/upgrade-resource-probe", preserve: true)
                machine.succeeds('osctl ct start limited')
                machine.wait_until_succeeds('osctl ct exec limited rc-service syslog status')
                limited_init = machine.osctl_json('ct show limited').fetch('init_pid')
                limited_identity = machine.succeeds("awk '{print $22}' /proc/#{limited_init}/stat")[1]

                # Resolve the actual controller mount, including combined v1 mounts.
                # Limits belong to the CT's base parent, not its payload leaf.
                cgroup_base = 'osctl/pool.tank/group.default/user.limited/ct.limited'
                cgroup_file = lambda do |parameter, relative = ""|
                  candidates = if cgroup_version == 2
                                 '/run/osctl/cgroup /sys/fs/cgroup'
                               else
                                 '/run/osctl/cgroup/* /sys/fs/cgroup/*'
                               end
                  path = File.join(cgroup_base, relative, parameter)
                  machine.succeeds("for root in #{candidates}; do file=\"$root/#{path}\"; if test -f \"$file\"; then echo \"$file\"; exit 0; fi; done; exit 1")[1].strip
                end
                read_parameter = lambda do |parameter, relative = ""|
                  machine.succeeds("cat #{Shellwords.escape(cgroup_file.call(parameter, relative))}")[1].strip
                end
                counter = lambda do |parameter, key, relative = ""|
                  output = read_parameter.call(parameter, relative)
                  key ? Integer(output.lines.find { |line| line.split.first == key }.split.last) : Integer(output)
                end
                probe_sequence = 0
                run_resource_probe = lambda do |mode|
                  probe_sequence += 1
                  prefix = "/run/upgrade-probe-#{probe_sequence}-#{mode}"
                  # Ruby loads inside the limited CT cgroup before the C probe starts.
                  # The observed predecessor bootstrap can exceed 40s at 25% CPU. Keep
                  # the C workload's own 30s alarm and budget bootstrap/exit separately.
                  machine.succeeds("(set +e; timeout 120 osctl ct exec limited /bin/upgrade-resource-probe #{mode} > #{prefix}.log 2>&1; echo $? > #{prefix}.status) < /dev/null > #{prefix}.launcher 2>&1 &")
                  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 150
                  loop do
                    status, = machine.execute("test -f #{prefix}.status", timeout: 10)
                    break if status == 0
                    fail "resource probe status missing: #{prefix}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

                    machine.execute(<<~SH, timeout: 15)
                      set +e
                      date -Ins
                      cat /proc/uptime /proc/loadavg
                      cat #{prefix}.log
                      for pid in $(pgrep -f 'osctld-ct-runner$|^osctld: tank:limited runner:|^/bin/upgrade-resource-probe'); do
                        echo "=== probe process $pid ==="
                        ps -p "$pid" -o pid,ppid,etimes,time,stat,wchan:24,args
                        cat /proc/$pid/stat /proc/$pid/schedstat /proc/$pid/cgroup
                        grep -E '^(State|VmRSS|Sig|Cpus_allowed_list)' /proc/$pid/status
                        cat /proc/$pid/syscall /proc/$pid/stack
                      done
                      for root in /run/osctl/cgroup /sys/fs/cgroup; do
                        test -d "$root" || continue
                        find "$root" -path '*user.limited/ct.limited/cpu.stat' -o -path '*user.limited/ct.limited/memory.events' -o -path '*user.limited/ct.limited/memory.oom_control' | while read file; do
                          echo "=== $file ==="
                          cat "$file"
                        done
                      done
                      true
                    SH
                    sleep(5)
                  end
                  output = machine.succeeds("cat #{prefix}.log")[1]
                  expect(machine.succeeds("cat #{prefix}.status")[1].strip).to eq('0')
                  expect(output).to include("probe_phase=#{mode} ", 'probe_phase=complete ')
                  if cgroup_version == 1 && %w[pids memory].include?(mode)
                    key = mode == 'pids' ? 'max' : 'oom_kill'
                    event = output.match(/probe_event=#{key} before=(\d+) after=(\d+)/)
                    expect(event).not_to be_nil
                    expect(Integer(event[2])).to be > Integer(event[1])
                  end
                end
                assert_limits = lambda do |cpu, pids, memory = 134217728, cpuset = '0'|
                  # LXC also applies CPU quotas to the persistent payload. Either
                  # enforcement point can exhaust its budget first; cpu.stat's
                  # bandwidth counters belong to each group, not the whole subtree.
                  cpu_groups = ["", "user-owned/lxc.payload.limited"]
                  cpu_groups.each do |relative|
                    expect(read_parameter.call(cgroup_version == 2 ? 'cpu.max' : 'cpu.cfs_quota_us', relative)).to eq(
                      cgroup_version == 2 ? "#{cpu * 1000} 100000" : (cpu * 1000).to_s,
                    )
                    expect(read_parameter.call('cpu.cfs_period_us', relative)).to eq('100000') if cgroup_version == 1
                  end
                  expect(read_parameter.call(cgroup_version == 2 ? 'memory.max' : 'memory.limit_in_bytes')).to eq(memory.to_s)
                  expect(read_parameter.call(cgroup_version == 2 ? 'memory.swap.max' : 'memory.memsw.limit_in_bytes')).to eq(
                    cgroup_version == 2 ? '0' : memory.to_s,
                  )
                  expect(read_parameter.call('pids.max')).to eq(pids.to_s)
                  expect(machine.succeeds("awk '/^Cpus_allowed_list:/ {print $2}' /proc/#{limited_init}/status")[1].strip).to eq(cpuset)
                  throttled = cpu_groups.to_h { |relative| [relative, counter.call('cpu.stat', 'nr_throttled', relative)] }
                  run_resource_probe.call('cpu')
                  after_throttled = cpu_groups.to_h { |relative| [relative, counter.call('cpu.stat', 'nr_throttled', relative)] }
                  expect(cpu_groups.any? { |relative| after_throttled.fetch(relative) > throttled.fetch(relative) }).to be(true),
                    "CPU quota did not throttle at either configured level: before=#{throttled.inspect}, after=#{after_throttled.inspect}"
                  # v1 local counters are measured inside the actual probe leaf before
                  # helper teardown removes it. v2 events propagate to the parent.
                  pids_denied = counter.call('pids.events', 'max') if cgroup_version == 2
                  run_resource_probe.call('pids')
                  expect(counter.call('pids.events', 'max')).to be > pids_denied if cgroup_version == 2
                  memory_denied = counter.call('memory.events', 'oom_kill') if cgroup_version == 2
                  run_resource_probe.call('memory')
                  expect(counter.call('memory.events', 'oom_kill')).to be > memory_denied if cgroup_version == 2
                  machine.succeeds('osctl ct exec limited dd if=/dev/zero of=/dev/null bs=1 count=1')
                  denied = machine.fails('osctl ct exec limited dd if=/dev/null of=/dev/zero bs=1 count=0')[1]
                  expect(denied).to include('Operation not permitted')
                  expect(machine.osctl_json('ct show limited').fetch('init_pid')).to eq(limited_init)
                  expect(machine.succeeds("awk '{print $22}' /proc/#{limited_init}/stat")[1]).to eq(limited_identity)
                end
                assert_limits.call(25, 64)

                # Real IDs and pins detect accidental replacement, not just reuse of
                # a path name. This device policy has no maps: compare that explicitly.
                bpf_identity = lambda do |ctid = 'limited'|
                  next nil if cgroup_version == 1
                  cgroup = File.dirname(cgroup_file.call('cgroup.procs')).sub('user.limited/ct.limited', "user.#{ctid}/ct.#{ctid}")
                  programs = JSON.parse(machine.succeeds("bpftool -j cgroup list #{cgroup}")[1])
                  device = programs.select { |program| program.fetch('attach_type') == 'cgroup_device' }
                  expect(device.length).to eq(1)
                  id = device.first.fetch('id')
                  program = JSON.parse(machine.succeeds("bpftool -j prog show id #{id}")[1])
                  expect(program.fetch('map_ids', [])).to eq([])
                  pins = machine.succeeds("for root in /run/osctl/bpf /sys/fs/bpf; do if test -d \"$root/osctl/pools/tank/links\"; then find \"$root/osctl/pools/tank/links\" -maxdepth 1 -name '*#{ctid}*'; fi; done")[1].lines.map(&:strip).uniq
                  expect(pins).not_to be_empty
                  # The predecessor bpftool's single-link query prints valid data but
                  # returns stale errno. Its full listing has a proper success path.
                  all_links = JSON.parse(machine.succeeds('bpftool -j -f link show')[1])
                  links = pins.map do |pin|
                    matches = all_links.select { |link| link.fetch('pinned', []).include?(pin) }
                    expect(matches.length).to eq(1)
                    link = matches.first
                    [File.basename(pin), link.fetch('id'), link.fetch('prog_id')]
                  end.uniq.sort
                  expect(links.map(&:last).uniq).to eq([id])
                  [id, program.fetch('tag'), program.fetch('map_ids', []), links]
                end
                inherited_bpf = bpf_identity.call

                # Include all three inherited stopped states, not only fresh objects
                # created by the new daemon. Do not start or mount neverstarted here.
                %w[neverstarted mountedstopped previouslyrun].each_with_index do |ctid, index|
                  machine.all_succeed(
                    "osctl ct new --distribution alpine #{ctid}",
                    "osctl ct unset start-menu #{ctid}",
                    "osctl ct netif new routed #{ctid} eth0",
                    "osctl ct netif ip add #{ctid} eth0 192.0.2.#{20 + index}/32",
                  )
                end
                machine.succeeds('osctl ct mount mountedstopped')
                mounted_root = machine.osctl_json('ct show mountedstopped').fetch('rootfs')
                machine.succeeds("echo mounted-data > #{Shellwords.escape(mounted_root)}/mounted-data")
                machine.succeeds('osctl ct start previouslyrun')
                machine.wait_until_succeeds('osctl ct exec previouslyrun rc-service networking status')
                machine.all_succeed(
                  "osctl ct exec previouslyrun sh -c 'echo predecessor-data > /root/retained'",
                  'osctl ct stop previouslyrun',
                )

                ${
                  if inheritedRecoveryTaint then
                    ''
                      # Row 33: create the *predecessor's* own recovery taint,
                      # not a healthy CT whose flag is merely false after switch.
                      machine.all_succeed(
                        'osctl ct new --distribution alpine inheritedtaint',
                        'osctl ct unset start-menu inheritedtaint',
                        'osctl ct netif new routed inheritedtaint eth0',
                        'osctl ct netif ip add inheritedtaint eth0 192.0.2.70/32',
                        'osctl ct start inheritedtaint',
                      )
                      machine.wait_until_succeeds('osctl ct exec inheritedtaint true', timeout: 90)
                      taint_veth = machine.osctl_json('ct netif ls inheritedtaint').find { |v| v.fetch('name') == 'eth0' }.fetch('veth')
                      machine.fails('osctl ct recover forget-host-link inheritedtaint eth0')
                      machine.succeeds("ip link delete #{taint_veth}")
                      machine.succeeds('osctl ct stop inheritedtaint')
                      taint_info = machine.osctl_json('ct show inheritedtaint')
                      expect(taint_info.fetch('state')).to eq('stopped')
                      expect(taint_info.fetch('recovery_tainted')).to be(true)
                      machine.fails('osctl ct start inheritedtaint')
                    ''
                  else
                    ""
                }

                guest_snapshots = {}
                ${
                  if !guestPolicies then
                    ""
                  else
                    ''
                      ${if name == "from-6.18" then "start_upgrade_access_trace(machine)" else ""}
                      # Real guest services, not replacement init or host-applied guest
                      # networking. Pin the older NixOS images used by resolver tests.
                      [
                        ['nmguest', 'fedora', '44', 'minimal', '192.0.2.30'],
                        ['nixold', 'nixos', '22.11', 'minimal', '192.0.2.31'],
                        ['niximpermanent', 'nixos', '24.05', 'impermanence', '192.0.2.32'],
                      ].each do |ctid, distribution, version, variant, address|
                        machine.all_succeed(
                          "osctl ct new --distribution #{distribution} --version #{version} --variant #{variant} #{ctid}",
                          "osctl ct unset start-menu #{ctid}",
                          "osctl ct netif new routed #{ctid} eth0",
                          "osctl ct netif ip add #{ctid} eth0 #{address}/32",
                          "osctl ct set dns-resolver #{ctid} 192.0.2.53",
                          "osctl ct start #{ctid}",
                        )
                        machine.wait_until_succeeds("ping -c 1 #{address}")
                        assert_guest_ready(machine, ctid)
                        if distribution == 'fedora'
                          # This network has no reachable package mirrors, so the pinned
                          # image's periodic dnf metadata refresh cannot succeed. Retire
                          # that timer before it can leave systemd degraded and mask the
                          # real state assertions; every other unit stays significant.
                          machine.succeeds(
                            "osctl ct exec #{ctid} sh -c 'systemctl mask --now dnf-makecache.timer dnf-makecache.service; systemctl reset-failed'"
                          )
                          # NetworkManager is only checked as active here. Handing DNS to the
                          # guest's own resolver manager is done after the userspace switch, where
                          # the host-side guard that keeps it from overwriting the configured
                          # resolver exists; see the resolver verification below.
                          machine.succeeds("osctl ct exec #{ctid} systemctl is-active NetworkManager.service")
                        else
                          expect(machine.succeeds("osctl ct exec #{ctid} nixos-version")[1].strip).to start_with(version)
                          machine.succeeds("osctl ct exec #{ctid} systemctl is-active networking-setup.service")
                        end
                        # Every pinned guest here runs its own resolver manager -- NetworkManager on
                        # fedora, systemd-resolved on NixOS -- which owns /etc/resolv.conf and
                        # re-establishes it during boot. A resolver configured while the container was
                        # stopped is retained by the host but is not visible inside such a guest after
                        # start.
                        #
                        # This block runs before the userspace switch, i.e. against the predecessor
                        # osctld that the case pins, and it deliberately removes the guest image's own
                        # dns=none line. That predecessor predates the host-side NetworkManager guard
                        # (etc/NetworkManager/conf.d/10-osctl-dns.conf) which keeps a resolver-manager
                        # guest from overwriting a live-applied resolver, so requiring the guest-visible
                        # line at this point would assert a capability the userspace in charge does not
                        # implement. Keep this phase to the host-side retention and the live apply; the
                        # exact resolv.conf line remains enforced on every guest after the switch by
                        # assert_retained and by the resolver verification loop, which additionally
                        # require the guard file to appear and disappear with set/unset.
                        expect(machine.osctl_json("ct show #{ctid}").fetch('dns_resolvers')).to eq(['192.0.2.53'])
                        machine.succeeds("osctl ct set dns-resolver #{ctid} 192.0.2.53")
                        info = machine.osctl_json("ct show #{ctid}")
                        expect(info.fetch('version')).to eq(version)
                        if variant == 'impermanence'
                          expect(info.fetch('impermanence')).to be(true)
                          expect(info.fetch('boot_dataset')).not_to eq(info.fetch('dataset'))
                          machine.all_succeed(
                            "osctl ct exec #{ctid} mountpoint -q /persistent",
                            "osctl ct exec #{ctid} sh -c 'echo inherited-persistent > /persistent/upgrade-retained; echo inherited-ephemeral > /upgrade-ephemeral'",
                          )
                        else
                          machine.succeeds("osctl ct exec #{ctid} sh -c 'echo inherited-persistent > /root/upgrade-retained'")
                        end
                        init = info.fetch('init_pid')
                        guest_snapshots[ctid] = {
                          distribution:, address:, init:,
                          impermanent: variant == 'impermanence',
                          boot_dataset: info.fetch('boot_dataset'),
                          init_start: machine.succeeds("awk '{print $22}' /proc/#{init}/stat")[1],
                          generation: distribution == 'nixos' ? machine.succeeds("osctl ct exec #{ctid} readlink /run/current-system")[1] : nil,
                          nm_pid: distribution == 'fedora' ? machine.succeeds("osctl ct exec #{ctid} systemctl show -p MainPID --value NetworkManager.service")[1] : nil,
                        }
                      end
                    ''
                }

                ${
                  if nestedDocker then
                    ''
                      # Preserve a predecessor-created Docker guest and live
                      # nested workload. Reuse the fresh docker/debian suite's
                      # bridge, package source, mirrors and nft alternative.
                      machine.all_succeed(
                        'osctl ct new --distribution debian --version latest nesteddocker',
                        'osctl ct unset start-menu nesteddocker',
                        'osctl ct netif new bridge --link lxcbr0 --no-dhcp --gateway-v4 auto --gateway-v6 none nesteddocker eth0',
                        'osctl ct netif ip add nesteddocker eth0 192.168.1.20/24',
                        'osctl ct set dns-resolver nesteddocker 1.1.1.1',
                        'osctl ct start nesteddocker',
                      )
                      machine.wait_until_container_online('nesteddocker')
                      docker_apt = lambda do |args|
                        machine.succeeds("osctl ct exec nesteddocker env DEBIAN_FRONTEND=noninteractive apt-get #{args}", timeout: 900)
                      end
                      docker_apt.call('update -y')
                      docker_apt.call('install -y ca-certificates curl')
                      machine.all_succeed(
                        'osctl ct exec nesteddocker install -m 0755 -d /etc/apt/keyrings',
                        'osctl ct exec nesteddocker curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc',
                        'osctl ct exec nesteddocker chmod a+r /etc/apt/keyrings/docker.asc',
                        %(osctl ct exec nesteddocker bash -c 'echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $(. /etc/os-release && echo $VERSION_CODENAME) stable" > /etc/apt/sources.list.d/docker.list'),
                      )
                      docker_apt.call('update -y')
                      docker_apt.call('install -y docker-ce docker-ce-cli containerd.io')
                      mirrors = Array(test_config.dig('docker', 'registryMirrors'))
                      unless mirrors.empty?
                        docker_root = machine.osctl_json('ct show nesteddocker').fetch('rootfs')
                        daemon_json = JSON.generate('registry-mirrors' => mirrors)
                        machine.succeeds("printf '%s\\n' #{Shellwords.escape(daemon_json)} > #{Shellwords.escape(docker_root)}/etc/docker/daemon.json")
                      end
                      machine.succeeds(<<~SH)
                        osctl ct exec nesteddocker sh -c '
                          for name in iptables ip6tables arptables ebtables; do
                            target="/usr/sbin/''${name}-nft"
                            if [ -x "$target" ] && update-alternatives --list "$name" 2>/dev/null | grep -Fxq "$target"; then
                              update-alternatives --set "$name" "$target"
                            fi
                          done'
                      SH
                      machine.succeeds('osctl ct exec nesteddocker systemctl restart docker')
                      machine.wait_until_succeeds('osctl ct exec nesteddocker docker info >/dev/null', timeout: 120)
                      machine.succeeds('osctl ct exec nesteddocker docker pull alpine:latest', timeout: 600)
                      machine.succeeds(%(osctl ct exec nesteddocker docker run -d --name inherited --network none alpine:latest sh -c 'echo inherited-nested-data > /root/upgrade-data; exec sleep 86400'), timeout: 180)
                      machine.wait_until_succeeds('osctl ct exec nesteddocker docker exec inherited grep -Fx inherited-nested-data /root/upgrade-data', timeout: 90)
                      nested_init = machine.osctl_json('ct show nesteddocker').fetch('init_pid')
                      nested_init_start = machine.succeeds("awk '{print $22}' /proc/#{nested_init}/stat")[1].strip
                      nested_identity = machine.succeeds('osctl ct exec nesteddocker docker inspect -f "{{.Id}} {{.State.Pid}}" inherited')[1].strip
                      expect(nested_identity.split.last.to_i).to be > 0
                    ''
                  else
                    ""
                }

                ${
                  if nestedPodman then
                    ''
                      # Use the fresh podman/debian fixture's bridge, tun
                      # device, DNS, distribution and Debian package source.
                      # The live nested workload is created on the old OS.
                      machine.all_succeed(
                        'osctl ct new --distribution debian --version latest nestedpodman',
                        'osctl ct unset start-menu nestedpodman',
                        'osctl ct netif new bridge --link lxcbr0 nestedpodman eth0',
                        'osctl ct devices add -p nestedpodman char 10 200 rwm /dev/net/tun',
                        'osctl ct set dns-resolver nestedpodman 1.1.1.1',
                        'osctl ct start nestedpodman',
                      )
                      machine.wait_until_container_online('nestedpodman')
                      podman_apt = lambda do |args|
                        machine.succeeds("osctl ct exec nestedpodman env DEBIAN_FRONTEND=noninteractive apt-get #{args}", timeout: 900)
                      end
                      podman_apt.call('update -y')
                      podman_apt.call('install -y podman')
                      mirrors = Array(test_config.dig('podman', 'dockerIoMirrors'))
                      unless mirrors.empty?
                        podman_root = machine.osctl_json('ct show nestedpodman').fetch('rootfs')
                        lines = ['[[registry]]', 'prefix = "docker.io"', 'location = "docker.io"', ""]
                        mirrors.each do |mirror|
                          lines << '  [[registry.mirror]]'
                          lines << %(  location = "#{mirror}")
                          lines << '  pull-from-mirror = "all"'
                          lines << ""
                        end
                        machine.succeeds("mkdir -p #{Shellwords.escape(podman_root)}/etc/containers/registries.conf.d")
                        machine.succeeds("printf '%s\\n' #{Shellwords.escape(lines.join("\n"))} > #{Shellwords.escape(podman_root)}/etc/containers/registries.conf.d/10-vpsadminos-mirror.conf")
                      end
                      _, podman_info = machine.succeeds('osctl ct exec nestedpodman podman info')
                      expect(podman_info).to match(/graphDriverName: overlay\s/)
                      machine.succeeds('osctl ct exec nestedpodman podman pull docker.io/library/alpine:latest', timeout: 600)
                      machine.succeeds(%(osctl ct exec nestedpodman podman run -d --name inherited --network none docker.io/library/alpine:latest sh -c 'echo inherited-podman-data > /root/upgrade-data; exec sleep 86400'), timeout: 180)
                      machine.wait_until_succeeds('osctl ct exec nestedpodman podman exec inherited grep -Fx inherited-podman-data /root/upgrade-data', timeout: 90)
                      podman_init = machine.osctl_json('ct show nestedpodman').fetch('init_pid')
                      podman_init_start = machine.succeeds("awk '{print $22}' /proc/#{podman_init}/stat")[1].strip
                      podman_identity = machine.succeeds('osctl ct exec nestedpodman podman inspect -f "{{.Id}} {{.State.Pid}}" inherited')[1].strip
                      expect(podman_identity.split.last.to_i).to be > 0
                    ''
                  else
                    ""
                }

                ${
                  if nestedIncus then
                    ''
                      # Reuse the fresh incus/debian fixture's dedicated
                      # nested ID range, bridge/IP, nesting, package source
                      # and preseed. Start the nested guest on the old OS.
                      require 'json'
                      incus_ip = "192.168.1.#{2 + 'debian-latest'.bytes.sum % 98}"
                      machine.succeeds('osctl user new --no-standalone --map 0:1600000:524288 nestedincus')
                      machine.all_succeed(
                        'osctl ct new --user nestedincus --distribution debian --version latest nestedincus',
                        'osctl ct unset start-menu nestedincus',
                        'osctl ct set nesting nestedincus',
                        'osctl ct netif new bridge --link lxcbr0 --no-dhcp --gateway-v4 auto --gateway-v6 none nestedincus eth0',
                        "osctl ct netif ip add nestedincus eth0 #{incus_ip}/24",
                        'osctl ct set dns-resolver nestedincus 192.168.1.1',
                        'osctl ct start nestedincus',
                      )
                      machine.wait_until_container_online('nestedincus')
                      incus_apt = lambda do |args|
                        machine.succeeds("osctl ct exec nestedincus env DEBIAN_FRONTEND=noninteractive apt-get #{args}", timeout: 900)
                      end
                      incus_apt.call('update -y')
                      incus_apt.call('install -y incus')
                      incus_rootfs = machine.osctl_json('ct show nestedincus').fetch('rootfs')
                      machine.all_succeed(
                        "printf '%s\\n' root:100000:65536 > #{Shellwords.escape(incus_rootfs)}/etc/subuid",
                        "printf '%s\\n' root:100000:65536 > #{Shellwords.escape(incus_rootfs)}/etc/subgid",
                      )
                      machine.succeeds(%(osctl ct exec nestedincus sh -c 'systemctl stop incus.service incus.socket 2>/dev/null || true; systemctl enable --now incus.socket || systemctl enable --now incus.service'))
                      machine.wait_until_succeeds(%(osctl ct exec nestedincus sh -c 'systemctl is-active --quiet incus.socket || systemctl is-active --quiet incus.service'), timeout: 120)
                      incus_preseed = <<~YAML
                        storage_pools:
                        - name: default
                          driver: dir
                        profiles:
                        - name: default
                          devices:
                            root:
                              path: /
                              pool: default
                              type: disk
                      YAML
                      # /tmp in a running guest may be a separate mount from
                      # the backing rootfs. Create the preseed inside the guest.
                      machine.succeeds("osctl ct exec nestedincus sh -c #{Shellwords.escape("printf '%s\\n' #{Shellwords.escape(incus_preseed)} > /tmp/incus-preseed.yaml")}")
                      machine.succeeds('osctl ct exec nestedincus sh -c "incus admin init --preseed < /tmp/incus-preseed.yaml"', timeout: 300)
                      # Both Debian and Alpine remotes stalled at image fetch
                      # on this native VM. Import a genuine, minimal container
                      # image from a static BusyBox already in the Nix closure;
                      # no external image server is part of this OS upgrade gate.
                      machine.push_file('${pkgs.pkgsStatic.busybox}/bin/busybox', "#{incus_rootfs}/root/incus-busybox", preserve: true)
                      incus_image_setup = <<~SH
                        set -eu
                        seed=/tmp/incus-upgrade-image
                        for path in bin sbin dev proc sys root tmp etc; do mkdir -p "$seed/rootfs/$path"; done
                        test -x /root/incus-busybox
                        cp /root/incus-busybox "$seed/rootfs/bin/busybox"
                        for command in sh sleep grep true; do ln -s busybox "$seed/rootfs/bin/$command"; done
                        echo 'root:x:0:0:root:/root:/bin/sh' > "$seed/rootfs/etc/passwd"
                        echo 'root:x:0:' > "$seed/rootfs/etc/group"
                        cat > "$seed/rootfs/sbin/init" <<'INIT'
                        #!/bin/sh
                        exec /bin/sleep 86400
                        INIT
                        chmod +x "$seed/rootfs/sbin/init"
                        chmod 1777 "$seed/rootfs/tmp"
                        cat > "$seed/metadata.yaml" <<META
                        architecture: $(uname -m)
                        creation_date: $(date +%s)
                        properties:
                          description: Offline inherited Incus upgrade fixture
                          os: minimal
                          release: "1"
                        META
                        tar -C "$seed" -czf "$seed/image.tar.gz" metadata.yaml rootfs
                        incus image import "$seed/image.tar.gz" --alias offline-inherited
                      SH
                      machine.succeeds("osctl ct exec nestedincus sh -c #{Shellwords.escape(incus_image_setup)}", timeout: 180)
                      machine.succeeds('osctl ct exec nestedincus incus image info offline-inherited', timeout: 60)
                      # An osctl exec timeout kills the Incus client before we
                      # can see why it is blocked. Keep its debug output and
                      # process available for bounded failure diagnostics.
                      init_nested_incus = lambda do |name|
                        incus_init_job = <<~SH
                          set -eu
                          rm -f /tmp/incus-#{name}-init.log /tmp/incus-#{name}-init.status /tmp/incus-#{name}-init.pid
                          nohup sh -c 'incus --debug init offline-inherited #{name} </dev/null >/tmp/incus-#{name}-init.log 2>&1; printf "%s\\n" $? >/tmp/incus-#{name}-init.status' >/dev/null 2>&1 &
                          echo $! >/tmp/incus-#{name}-init.pid
                        SH
                        machine.succeeds("osctl ct exec nestedincus sh -c #{Shellwords.escape(incus_init_job)}", timeout: 30)
                        begin
                          machine.wait_until_succeeds("osctl ct exec nestedincus test -f /tmp/incus-#{name}-init.status", timeout: 180)
                          machine.succeeds("osctl ct exec nestedincus grep -Fx 0 /tmp/incus-#{name}-init.status", timeout: 30)
                        rescue StandardError
                          [
                            "cat /tmp/incus-#{name}-init.log",
                            "cat /tmp/incus-#{name}-init.status",
                            'ps -eo pid,ppid,stat,wchan:24,args',
                            'incus storage list',
                            'incus profile show default',
                            'incus operation list',
                            'incus image info offline-inherited',
                            "incus info --show-log #{name}",
                            'journalctl -u incus.service -u incus.socket -n 90 --no-pager',
                          ].each do |command|
                            begin
                              status, output, error = machine.execute("osctl ct exec nestedincus #{command}", timeout: 30)
                              warn "Incus #{name} init diagnostic #{command} (#{status}): #{output}\n#{error}"
                            rescue StandardError => diagnostic_error
                              warn "Incus #{name} init diagnostic #{command} unavailable: #{diagnostic_error}"
                            end
                          end
                          machine.execute("osctl ct exec nestedincus sh -c #{Shellwords.escape("kill $(cat /tmp/incus-#{name}-init.pid) 2>/dev/null || true")}", timeout: 15)
                          raise
                        end
                      end
                      start_nested_incus = lambda do |name|
                        launcher = "rm -f /tmp/incus-#{name}-start.log; nohup sh -c 'incus start #{name} > /tmp/incus-#{name}-start.log 2>&1' >/dev/null 2>&1 &"
                        machine.succeeds("osctl ct exec nestedincus sh -c #{Shellwords.escape(launcher)}")
                        machine.wait_until_succeeds(
                          "osctl ct exec nestedincus sh -c #{Shellwords.escape("incus info #{name} | grep -q 'Status: RUNNING'")}",
                          timeout: 300,
                        )
                      rescue StandardError
                        begin
                          _, start_log = machine.execute("osctl ct exec nestedincus cat /tmp/incus-#{name}-start.log", timeout: 30)
                          warn "Incus #{name} start diagnostic: #{start_log}"
                        rescue StandardError => diagnostic_error
                          warn "Incus #{name} start diagnostic unavailable: #{diagnostic_error}"
                        end
                        raise
                      end
                      init_nested_incus.call('inherited')
                      start_nested_incus.call('inherited')
                      machine.wait_until_succeeds('osctl ct exec nestedincus incus exec inherited -- true', timeout: 300)
                      machine.succeeds(%(osctl ct exec nestedincus incus exec inherited -- sh -c 'echo predecessor-incus-data > /root/upgrade-data'))
                      machine.wait_until_succeeds('osctl ct exec nestedincus incus exec inherited -- grep -Fx predecessor-incus-data /root/upgrade-data', timeout: 90)
                      incus_host_init = machine.osctl_json('ct show nestedincus').fetch('init_pid')
                      incus_host_start = machine.succeeds("awk '{print $22}' /proc/#{incus_host_init}/stat")[1].strip
                      incus_info = machine.succeeds('osctl ct exec nestedincus incus info inherited')[1]
                      expect(incus_info).to include('Status: RUNNING', 'Type: container')
                      incus_guest_pid = Integer(incus_info[/^PID:\s*(\d+)\s*$/, 1], 10)
                      expect(incus_guest_pid).to be > 0
                      incus_guest_start = machine.succeeds("osctl ct exec nestedincus awk '{print $22}' /proc/#{incus_guest_pid}/stat")[1].strip
                    ''
                  else
                    ""
                }

                ${
                  if frozenActivation then
                    ''
                      # The published predecessor's osctld freeze frontend
                      # enters a syslog namespace and gets EPERM on this
                      # kernel before it can call LXC. Seed a real frozen
                      # guest through that predecessor's LXC freezer instead;
                      # its daemon may cache RUNNING until target activation.
                      machine.all_succeed(
                        'osctl ct new --distribution alpine inheritedfrozen',
                        'osctl ct unset start-menu inheritedfrozen',
                        'osctl ct netif new routed inheritedfrozen eth0',
                        'osctl ct netif ip add inheritedfrozen eth0 192.0.2.54/32',
                        'osctl ct start inheritedfrozen',
                      )
                      machine.wait_until_succeeds('osctl ct exec inheritedfrozen true', timeout: 90)
                      machine.succeeds(%(osctl ct exec inheritedfrozen sh -c 'echo predecessor-frozen > /root/frozen-data'))
                      frozen_info = machine.osctl_json('ct show inheritedfrozen')
                      frozen_init = frozen_info.fetch('init_pid')
                      frozen_init_start = machine.succeeds("awk '{print $22}' /proc/#{frozen_init}/stat")[1].strip
                      frozen_rootfs = frozen_info.fetch('rootfs')
                      frozen_lxc_home = File.dirname(machine.succeeds('osctl ct show -H -o lxc_dir inheritedfrozen')[1].strip)
                      frozen_lxc_state = "${pkgs.lxc}/bin/lxc-info -n inheritedfrozen -P #{Shellwords.escape(frozen_lxc_home)} -s"
                      machine.succeeds("${pkgs.lxc}/bin/lxc-freeze -n inheritedfrozen -P #{Shellwords.escape(frozen_lxc_home)}")
                      machine.wait_until_succeeds("#{frozen_lxc_state} | grep -Eq '^State:[[:space:]]*FROZEN$'", timeout: 90)
                      assert_frozen = lambda do |phase, daemon_state: true|
                        machine.wait_until_succeeds("#{frozen_lxc_state} | grep -Eq '^State:[[:space:]]*FROZEN$'", timeout: 30)
                        frozen_current = machine.osctl_json('ct show inheritedfrozen')
                        expect(frozen_current.fetch('state')).to eq('frozen'), "#{phase}: daemon lost frozen state" if daemon_state
                        expect(frozen_current.fetch('init_pid')).to eq(frozen_init), "#{phase}: replaced frozen init"
                        expect(machine.succeeds("awk '{print $22}' /proc/#{frozen_init}/stat")[1].strip).to eq(frozen_init_start), "#{phase}: reused frozen PID"
                        machine.succeeds("grep -Fx predecessor-frozen #{Shellwords.escape(frozen_rootfs)}/root/frozen-data")
                      end
                      assert_frozen.call('predecessor', daemon_state: false)
                    ''
                  else
                    ""
                }

                snapshots = {}
                create_workload = lambda do |ctid, address, create: true, start: true|
                  if create
                    machine.all_succeed(
                      "osctl ct new --distribution alpine #{ctid}",
                      "osctl ct unset start-menu #{ctid}",
                      "osctl ct netif new routed #{ctid} eth0",
                      "osctl ct netif ip add #{ctid} eth0 #{address}/32",
                      "osctl ct mount #{ctid}",
                    )
                  end
                  info = machine.osctl_json("ct show #{ctid}")
                  # The minimal image does not install an HTTP server. Supply the
                  # workload explicitly, not as an assumed guest package or policy.
                  machine.push_file('${pkgs.pkgsStatic.busybox}/bin/busybox', "#{info.fetch('rootfs')}/sbin/upgrade-busybox", preserve: true)
                  machine.push_file('${workload}', "#{info.fetch('rootfs')}/sbin/upgrade-workload", preserve: true)
                  machine.succeeds("osctl ct set init-cmd #{ctid} /sbin/upgrade-workload")
                  unless start
                    machine.succeeds("echo activated-generation-data > #{Shellwords.escape(info.fetch('rootfs'))}/activated-generation-data")
                    next
                  end
                  machine.succeeds("osctl ct start #{ctid}")
                  machine.wait_until_succeeds("osctl ct exec #{ctid} test -s /upgrade/worker.pid")
                  info = machine.osctl_json("ct show #{ctid}")
                  init = info.fetch('init_pid').to_i
                  expect(init).to be > 1
                  netif = machine.osctl_json("ct netif ls #{ctid}").find { |v| v.fetch('name') == 'eth0' }
                  veth = netif.fetch('veth')
                  machine.all_succeed(
                    "ping -c 1 #{address}",
                    "curl --fail --max-time 10 http://#{address}:8080/data | grep -Fx retained-data || { osctl ct exec #{ctid} cat /upgrade/http.log; exit 1; }",
                    "ruby /root/upgrade-console.rb #{ctid} before-upgrade",
                    "! tr '\\0' '\\n' < /proc/#{init}/environ | grep -q '^OSCTL_RUN_ID='",
                  )
                  prefix = "/run/upgrade-stream-#{ctid}"
                  machine.succeeds("ruby /root/upgrade-tcp-stream.rb #{address} #{prefix} > #{prefix}.log 2>&1 & echo $! > #{prefix}.pid")
                  machine.wait_until_succeeds("test -s #{prefix}.progress")
                  stream = JSON.parse(machine.succeeds("cat #{prefix}.progress")[1])
                  stream_pid = machine.succeeds("cat #{prefix}.pid")[1].strip
                  snapshots[ctid] = {
                    address:,
                    init:,
                    init_start: machine.succeeds("awk '{print $22}' /proc/#{init}/stat")[1],
                    cgroup: machine.succeeds("cat /proc/#{init}/cgroup")[1],
                    mounts: machine.succeeds("cat /proc/#{init}/mountinfo")[1],
                    bpf: bpf_identity.call(ctid),
                    veth:,
                    ifindex: machine.succeeds("cat /sys/class/net/#{veth}/ifindex")[1],
                    console: machine.succeeds("stat -c %i /run/osctl/pools/tank/console/#{ctid}/tty0.sock")[1],
                    worker: machine.succeeds("osctl ct exec #{ctid} sh -c 'cat /proc/$(cat /upgrade/worker.pid)/stat'")[1].split.values_at(0, 21),
                    http: machine.succeeds("osctl ct exec #{ctid} sh -c 'cat /proc/$(cat /upgrade/http.pid)/stat'")[1].split.values_at(0, 21),
                    tcp: machine.succeeds("osctl ct exec #{ctid} sh -c 'cat /proc/$(cat /upgrade/tcp.pid)/stat'")[1].split.values_at(0, 21),
                    stream_prefix: prefix,
                    stream_port: stream.fetch('port'),
                    stream_pid:,
                    stream_start: machine.succeeds("awk '{print $22}' /proc/#{stream_pid}/stat")[1],
                  }
                end

                assert_retained = lambda do
                  guest_snapshots.each do |ctid, saved|
                    info = machine.osctl_json("ct show #{ctid}")
                    expect(info.fetch('init_pid')).to eq(saved.fetch(:init))
                    expect(info.fetch('dns_resolvers')).to eq(['192.0.2.53'])
                    expect(machine.succeeds("awk '{print $22}' /proc/#{saved.fetch(:init)}/stat")[1]).to eq(saved.fetch(:init_start))
                    expect(info.fetch('boot_dataset')).to eq(saved.fetch(:boot_dataset))
        marker = saved.fetch(:impermanent) ? '/persistent/upgrade-retained' : '/root/upgrade-retained'
                    machine.succeeds("osctl ct exec #{ctid} grep -Fx inherited-persistent #{marker}")
                    if saved.fetch(:impermanent)
                      machine.succeeds("osctl ct exec #{ctid} grep -Fx inherited-ephemeral /upgrade-ephemeral")
                    end
                    assert_guest_ready(machine, ctid)
                    # These pinned guests run their own resolver tooling: NetworkManager on fedora
                    # (held back by the host-side guard) and resolvconf/systemd-resolved on the NixOS
                    # images pinned by older predecessors, whose networking-setup regenerates
                    # /etc/resolv.conf from the image's own networking.nameservers on network events.
                    # A host-written resolver is therefore not durable across such an event, while the
                    # configured intent itself is what the host-side dns_resolvers check above proves
                    # survived the switch. Guest visibility is the observable of a live application, so
                    # apply the configured resolver again and then require the exact line, as the
                    # resolver verification below does.
                    machine.succeeds("osctl ct set dns-resolver #{ctid} 192.0.2.53")
                    machine.succeeds("osctl ct exec #{ctid} grep -Fx 'nameserver 192.0.2.53' /etc/resolv.conf")
                    machine.succeeds("ping -c 1 #{saved.fetch(:address)}")
                    if saved.fetch(:distribution) == 'nixos'
                      expect(machine.succeeds("osctl ct exec #{ctid} readlink /run/current-system")[1]).to eq(saved.fetch(:generation))
                      machine.succeeds("osctl ct exec #{ctid} systemctl is-active networking-setup.service")
                    else
                      # NetworkManager may restart independently of the CT's
                      # init. Require a live service, the DNS line and working
                      # network above; a transient guest service PID is not a
                      # host activation identity.
                      machine.succeeds("osctl ct exec #{ctid} systemctl is-active NetworkManager.service")
                      nm_pid = machine.succeeds("osctl ct exec #{ctid} systemctl show -p MainPID --value NetworkManager.service")[1]
                      warn "#{ctid} NetworkManager PID changed: #{saved.fetch(:nm_pid).strip} -> #{nm_pid.strip}" if nm_pid != saved.fetch(:nm_pid)
                      expect(Integer(nm_pid)).to be_positive
                    end
                  end
                  expect(machine.osctl_json('ct show limited').fetch('init_pid')).to eq(limited_init)
                  machine.succeeds('osctl ct exec limited grep -Fx inherited-bind /mnt/inherited/marker')
                  expect(bpf_identity.call).to eq(inherited_bpf)
                  snapshots.each do |ctid, saved|
                    info = machine.osctl_json("ct show #{ctid}")
                    expect(info.fetch('state')).to eq('running')
                    expect(info.fetch('init_pid').to_i).to eq(saved.fetch(:init))
                    init = saved.fetch(:init)
                    expect(machine.succeeds("awk '{print $22}' /proc/#{init}/stat")[1]).to eq(saved.fetch(:init_start))
                    expect(machine.succeeds("cat /proc/#{init}/cgroup")[1]).to eq(saved.fetch(:cgroup))
                    expect_mounts_unchanged.call(
                      "#{ctid} mounts changed after the switch",
                      saved.fetch(:mounts),
                      machine.succeeds("cat /proc/#{init}/mountinfo")[1]
                    )
                    expect(bpf_identity.call(ctid)).to eq(saved.fetch(:bpf))
                    netif = machine.osctl_json("ct netif ls #{ctid}").find { |v| v.fetch('name') == 'eth0' }
                    expect(netif.fetch('veth')).to eq(saved.fetch(:veth))
                    expect(machine.succeeds("cat /sys/class/net/#{saved.fetch(:veth)}/ifindex")[1]).to eq(saved.fetch(:ifindex))
                    expect(machine.succeeds("stat -c %i /run/osctl/pools/tank/console/#{ctid}/tty0.sock")[1]).to eq(saved.fetch(:console))
                    worker = machine.succeeds("osctl ct exec #{ctid} sh -c 'cat /proc/$(cat /upgrade/worker.pid)/stat'")[1].split.values_at(0, 21)
                    expect(worker).to eq(saved.fetch(:worker))
                    http = machine.succeeds("osctl ct exec #{ctid} sh -c 'cat /proc/$(cat /upgrade/http.pid)/stat'")[1].split.values_at(0, 21)
                    expect(http).to eq(saved.fetch(:http))
                    tcp = machine.succeeds("osctl ct exec #{ctid} sh -c 'cat /proc/$(cat /upgrade/tcp.pid)/stat'")[1].split.values_at(0, 21)
                    expect(tcp).to eq(saved.fetch(:tcp))
                    prefix = saved.fetch(:stream_prefix)
                    machine.succeeds("test ! -e #{prefix}.error && kill -0 #{saved.fetch(:stream_pid)}")
                    expect(machine.succeeds("awk '{print $22}' /proc/#{saved.fetch(:stream_pid)}/stat")[1]).to eq(saved.fetch(:stream_start))
                    stream = JSON.parse(machine.succeeds("cat #{prefix}.progress")[1])
                    expect(stream.fetch('port')).to eq(saved.fetch(:stream_port))
                    machine.all_succeed(
                      "osctl ct exec #{ctid} grep -Fx retained-data /upgrade/data",
                      "ruby /root/upgrade-console.rb #{ctid} after-upgrade",
                      "ping -c 1 #{saved.fetch(:address)}",
                      "curl --fail --max-time 10 http://#{saved.fetch(:address)}:8080/data | grep -Fx retained-data",
                    )
                  end
                end
                %w[upgrade1 upgrade2].each_with_index do |ctid, index|
                  create_workload.call(ctid, "192.0.2.#{10 + index}")
                end

                activate_generation = lambda do |target, release_on_drain: nil|
                  prior_daemon = daemon_identity.call
                  sequences = snapshots.transform_values do |saved|
                    JSON.parse(machine.succeeds("cat #{saved.fetch(:stream_prefix)}.progress")[1]).fetch('sequence')
                  end
                  if release_on_drain
                    # The blocked old-daemon commands must still be in flight
                    # when the generation switch reaches its client-drain phase.
                    machine.succeeds('test -S /run/osctl/osctld.sock')
                    machine.succeeds("(status=0; #{target}/bin/switch-to-configuration test || status=$?; echo \"$status\" > /overlap-management-switch.status) > /overlap-management-switch.log 2>&1 < /dev/null & echo $! > /overlap-management-switch.pid")
                    begin
                      machine.wait_until_succeeds('test ! -S /run/osctl/osctld.sock', timeout: 120)
                      machine.succeeds('test ! -e /overlap-management-switch.status && test ! -e /overlap-management-start.status && test ! -e /overlap-management-copy.status')
                      ${
                        if mountingActivation then "machine.succeeds('test ! -e /overlap-pre-mount.status')" else ""
                      }
                    ensure
                      # Never leave the old daemon blocked on our test hooks.
                      release_on_drain.call
                    end
                    machine.wait_until_succeeds('test -s /overlap-management-switch.status', timeout: 300)
                    machine.succeeds('grep -Fx 0 /overlap-management-switch.status')
                  else
                    machine.succeeds("#{target}/bin/switch-to-configuration test", timeout: 300)
                  end
                  # Keep the same connections transferring ordered data during the
                  # activation, not just fresh connections before and afterwards.
                  snapshots.each do |ctid, saved|
                    prefix = saved.fetch(:stream_prefix)
                    machine.succeeds("test ! -e #{prefix}.error")
                    stream = JSON.parse(machine.succeeds("cat #{prefix}.progress")[1])
                    expect(stream.fetch('sequence')).to be > sequences.fetch(ctid)
                    expect(stream.fetch('port')).to eq(saved.fetch(:stream_port))
                  end
                  machine.wait_for_osctl_pool('tank')
                  expect(machine.succeeds('uname -r')[1].strip).to eq(before_kernel)
                  expect(machine.succeeds('cat /proc/sys/kernel/random/boot_id')[1].strip).to eq(before_boot)
                  expect(machine.succeeds('readlink -f /run/booted-system')[1].strip).to eq(booted_system)
                  expect(machine.succeeds('readlink -f /run/current-system')[1].strip).to eq(target)
                  expect(daemon_identity.call).not_to eq(prior_daemon)
                  expect(machine.succeeds('stat -c %d:%i /run/osctl/bpf')[1].strip).to eq(before_bpffs)
                  expect(machine.succeeds('stat -f -c %T /run/osctl/bpf')[1].strip).to eq('bpf_fs')
                  assert_retained.call
                  ${
                    if inheritedRecoveryTaint then
                      ''
                        taint_info = machine.osctl_json('ct show inheritedtaint')
                        expect(taint_info.fetch('state')).to eq('stopped')
                        expect(taint_info.fetch('recovery_tainted')).to be(true)
                        machine.fails('osctl ct start inheritedtaint')
                      ''
                    else
                      ""
                  }
                end

                ${
                  if activatedSystem == null then
                    ""
                  else
                    ''
                      # Booted B remains unchanged while state from B and activated A
                      # coexist. The named case fixes A's revision; no live inventory.
                      activate_generation.call('${activatedSystem}')
                      expect('${activatedSystem}').not_to eq(booted_system)
                      # This frozen userspace cannot start new CTs after the v1 live
                      # switch: its LXC requires the missing /run/osctl/cgroup. Do not
                      # repair A in the fixture. Retain A-created stopped state and
                      # require T to start it, alongside the continuously running B CTs.
                      create_workload.call('activegeneration', '192.0.2.13', start: false)
                      assert_limits.call(25, 64)
                    ''
                }

                ${
                  if transferAcrossActivation then
                    ''
                      # Row 31 — produce the stream with the booted predecessor
                      # daemon, then import it with the target daemon below.
                      # Keep this stopped guest separate from the long-lived
                      # workload CTs so their connections are not interrupted.
                      machine.all_succeed(
                        'osctl ct new --distribution alpine transferold',
                        'osctl ct unset start-menu transferold',
                        'osctl ct mount transferold',
                      )
                      transfer_root = machine.osctl_json('ct show transferold').fetch('rootfs')
                      transfer_dataset = machine.osctl_json('ct show transferold').fetch('dataset')
                      machine.all_succeed(
                        "zfs set acltype=posixacl #{transfer_dataset}",
                        "mkdir -p #{transfer_root}/upgrade-transfer",
                        "echo predecessor-data > #{transfer_root}/upgrade-transfer/plain",
                        "chown 1234:5678 #{transfer_root}/upgrade-transfer/plain",
                        "chmod 640 #{transfer_root}/upgrade-transfer/plain",
                        "${pkgs.attr}/bin/setfattr -n user.delivery -v predecessor #{transfer_root}/upgrade-transfer/plain",
                        "echo acl > #{transfer_root}/upgrade-transfer/acl",
                        "${pkgs.acl}/bin/setfacl -m u:4321:rwx #{transfer_root}/upgrade-transfer/acl",
                        "echo filecap > #{transfer_root}/upgrade-transfer/filecap",
                        "chmod 755 #{transfer_root}/upgrade-transfer/filecap",
                        "${pkgs.libcap}/bin/setcap cap_chown=ep #{transfer_root}/upgrade-transfer/filecap",
                        "dd if=/dev/urandom of=#{transfer_root}/upgrade-transfer/blob bs=1024 count=32 status=none",
                        "sha256sum #{transfer_root}/upgrade-transfer/blob | awk '{print $1}' > /root/upgrade-transfer.sha",
                        'osctl ct export transferold /root/upgrade-transfer.tar',
                        'test -s /root/upgrade-transfer.tar',
                        'osctl ct del -f --prune transferold',
                      )
                    ''
                  else
                    ""
                }

                ${
                  if overlapActivation then
                    ''
                      # Row 30 — management operations in flight across the
                      # userspace activation below. Successful operations must
                      # finish their guest work; cancellation must be the known
                      # daemon-connection closure, not an arbitrary numeric error.
                      # Both must conclude within a bound and leave no runner.
                      rootfs1 = machine.osctl_json('ct show upgrade1').fetch('rootfs')
                      rootfs2 = machine.osctl_json('ct show upgrade2').fetch('rootfs')
                      # OsVm enables errexit/pipefail. Observe failures explicitly
                      # so cancellation writes its real status instead of making
                      # the parent wait for a status file that will never exist.
                      start_overlap_operation = lambda do |kind, command|
                        machine.succeeds("(status=0; #{command} || status=$?; echo \"$status\" > /overlap-#{kind}.status) > /overlap-#{kind}.log 2>&1 < /dev/null & echo $! > /overlap-#{kind}.pid")
                      end
                      begin
                      # Hold a real old-generation management connection with
                      # an unfinished protocol frame. Shutdown must close it,
                      # not execute it or leave a blocked client handler behind.
                      overlap_client = <<~CLIENT
                        require 'socket'
                        require 'json'
                        socket = UNIXSocket.new('/run/osctl/osctld.sock')
                        begin
                          abort 'management greeting timed out' unless IO.select([socket], nil, nil, 30)
                          hello = JSON.parse(socket.gets)
                          abort 'invalid management greeting' unless hello.fetch('version').is_a?(String)
                          socket.write('{"cmd":"ct_list","opts":')
                          File.write('/overlap-client.started', 'partial request')
                          abort 'management close timed out' unless IO.select([socket], nil, nil, 180)
                          # recv reports a closed peer as nil or an empty string.
                          response = socket.recv(1024)
                          abort 'partial request unexpectedly received a response' unless response.nil? || response.empty?
                        rescue Errno::ECONNRESET
                          raise unless File.exist?('/overlap-client.started')
                        ensure
                          socket.close
                        end
                      CLIENT
                      machine.succeeds("printf %s #{Shellwords.escape(overlap_client)} > /root/overlap-client.rb")
                      start_overlap_operation.call('client', '${pkgs.ruby}/bin/ruby /root/overlap-client.rb')
                      overlap_script = "#!/bin/sh\necho started > /overlap-runscript.started\nsleep 60\necho overlap-runscript-done > /overlap-runscript\n"
                      start_overlap_operation.call('exec', "osctl ct exec upgrade1 sh -c 'echo started > /overlap-exec.started; sleep 60; echo overlap-exec-done > /overlap-exec'")
                      start_overlap_operation.call('runscript', "printf %s #{Shellwords.escape(overlap_script)} | osctl ct runscript upgrade2 -")
                      # A background client PID alone does not prove the guest
                      # operation is in flight. Observe both guest-written
                      # start markers through their already-mounted rootfs.
                      machine.wait_until_succeeds("test -s #{rootfs1}/overlap-exec.started && test -s #{rootfs2}/overlap-runscript.started && test -s /overlap-client.started", timeout: 60)
                      machine.succeeds('test ! -e /overlap-exec.status && test ! -e /overlap-runscript.status && test ! -e /overlap-client.status')
                    ''
                  else
                    ""
                }
                ${
                  if managementActivation then
                    ''
                      # Keep real predecessor commands inside their hooks until
                      # the old daemon drains for the target generation switch.
                      # Separate CTs prevent the per-CT lock from serializing
                      # start and copy with one another before the switch.
                      begin
                        machine.all_succeed(
                          'osctl ct new --distribution alpine managementstart',
                          'osctl ct unset start-menu managementstart',
                          'osctl ct mount managementstart',
                          'osctl ct new --distribution alpine managementcopy',
                          'osctl ct unset start-menu managementcopy',
                          'osctl ct start managementcopy',
                          'osctl ct cp config managementcopy managementcopy-dst',
                          'osctl ct cp rootfs managementcopy',
                        )
                        start_root = machine.osctl_json('ct show managementstart').fetch('rootfs')
                        copy_root = machine.osctl_json('ct show managementcopy').fetch('rootfs')
                        machine.all_succeed(
                          "printf 'predecessor-start\\n' > #{start_root}/root/upgrade-start",
                          "printf 'predecessor-copy\\n' > #{copy_root}/root/upgrade-copy",
                        )

                        [['managementstart', 'pre-start', 'start'],
                         ['managementcopy', 'pre-stop', 'copy']].each do |ctid, hook, kind|
                          path = "/tank/hook/ct/#{ctid}/#{hook}"
                          machine.succeeds(<<~SH)
                            install -d -m 700 #{Shellwords.escape(File.dirname(path))}
                            cat > #{Shellwords.escape(path)} <<'HOOK'
                            #!/bin/sh
                            set -eu
                            : > /overlap-management-#{kind}.started
                            while [ ! -e /overlap-management-#{kind}.release ]; do
                              sleep 0.1
                            done
                            HOOK
                            chmod 700 #{Shellwords.escape(path)}
                          SH
                        end
                        start_management_operation = lambda do |kind, command|
                          machine.succeeds("(status=0; #{command} || status=$?; echo \"$status\" > /overlap-management-#{kind}.status) > /overlap-management-#{kind}.log 2>&1 < /dev/null & echo $! > /overlap-management-#{kind}.pid")
                        end
                        start_management_operation.call('start', 'osctl ct start managementstart')
                        start_management_operation.call('copy', 'osctl ct cp state managementcopy')
                        machine.wait_until_succeeds('test -e /overlap-management-start.started && test -e /overlap-management-copy.started', timeout: 90)
                        machine.succeeds('test ! -e /overlap-management-start.status && test ! -e /overlap-management-copy.status')
                        activate_generation.call(
                          '${nextSystem}',
                          release_on_drain: lambda do
                            machine.succeeds('touch /overlap-management-start.release /overlap-management-copy.release')
                          end,
                        )
                    ''
                  else if mountingActivation then
                    ''
                      # LXC's pre-mount hook runs inside the mount namespace
                      # before the guest rootfs is attached, after pre-start.
                      # Keep that real mounting phase across daemon handoff.
                      begin
                        machine.all_succeed(
                          'osctl ct new --distribution alpine mounttransition',
                          'osctl ct unset start-menu mounttransition',
                          'osctl ct mount mounttransition',
                        )
                        mount_root = machine.osctl_json('ct show mounttransition').fetch('rootfs')
                        machine.succeeds("printf 'predecessor-mount-data\\n' > #{mount_root}/root/upgrade-mount")
                        mount_hook = '/tank/hook/ct/mounttransition/pre-mount'
                        machine.succeeds(<<~SH)
                          install -d -m 700 #{Shellwords.escape(File.dirname(mount_hook))}
                          cat > #{Shellwords.escape(mount_hook)} <<'HOOK'
                          #!/bin/sh
                          set -eu
                          test -n "$OSCTL_CT_ROOTFS_MOUNT"
                          : > /overlap-pre-mount.started
                          while [ ! -e /overlap-pre-mount.release ]; do
                            sleep 0.1
                          done
                          HOOK
                          chmod 700 #{Shellwords.escape(mount_hook)}
                        SH
                        machine.succeeds('(status=0; osctl ct start mounttransition || status=$?; echo "$status" > /overlap-pre-mount.status) > /overlap-pre-mount.log 2>&1 < /dev/null & echo $! > /overlap-pre-mount.pid')
                        machine.wait_until_succeeds('test -e /overlap-pre-mount.started', timeout: 90)
                        machine.succeeds('test ! -e /overlap-pre-mount.status')
                        activate_generation.call(
                          '${nextSystem}',
                          release_on_drain: lambda do
                            machine.succeeds('touch /overlap-pre-mount.release')
                          end,
                        )
                    ''
                  else
                    "activate_generation.call('${nextSystem}')"
                }

                ${
                  if managementActivation then
                    ''
                        machine.wait_until_succeeds('test -s /overlap-management-start.status && test -s /overlap-management-copy.status', timeout: 180)
                        %w[start copy].each do |kind|
                          status = Integer(machine.succeeds("cat /overlap-management-#{kind}.status")[1].strip, 10)
                          log = machine.succeeds("tail -c 8192 /overlap-management-#{kind}.log")[1]
                          expect(status).to eq(0), "#{kind} failed across activation: #{log}"
                        end
                        machine.succeeds('osctl ct exec managementstart grep -Fx predecessor-start /root/upgrade-start')
                        machine.succeeds('osctl ct cp cleanup managementcopy')
                        machine.succeeds('osctl ct start managementcopy-dst')
                        machine.succeeds('osctl ct exec managementcopy-dst grep -Fx predecessor-copy /root/upgrade-copy')
                        machine.all_succeed(
                          'rm -f /tank/hook/ct/managementstart/pre-start /tank/hook/ct/managementcopy/pre-stop',
                          'osctl ct del -f --prune managementstart',
                          'osctl ct del -f --prune managementcopy',
                          'osctl ct del -f --prune managementcopy-dst',
                        )
                      ensure
                        overlap_error = $!
                        begin
                          machine.execute('touch /overlap-management-start.release /overlap-management-copy.release', timeout: 30)
                          if overlap_error
                            machine.execute(<<~SH, timeout: 30)
                              for kind in start copy switch; do
                                for part in pid status log; do
                                  file=/overlap-management-$kind.$part
                                  echo "===== $file ====="
                                  if test -f "$file"; then tail -c 8192 "$file"; fi
                                done
                                if test -s /overlap-management-$kind.pid; then
                                  ps -p "$(cat /overlap-management-$kind.pid)" -o pid,ppid,state,args || true
                                fi
                              done
                            SH
                          end
                        rescue StandardError => diagnostic_error
                          warn "Unable to retain management overlap diagnostics: #{diagnostic_error}"
                        end
                      end
                    ''
                  else
                    ""
                }

                ${
                  if mountingActivation then
                    ''
                        machine.wait_until_succeeds('test -s /overlap-pre-mount.status', timeout: 180)
                        mount_status = Integer(machine.succeeds('cat /overlap-pre-mount.status')[1].strip, 10)
                        mount_log = machine.succeeds('tail -c 8192 /overlap-pre-mount.log')[1]
                        expect(mount_status).to eq(0), "pre-mount start failed across activation: #{mount_log}"
                        expect(machine.osctl_json('ct show mounttransition').fetch('state')).to eq('running')
                        machine.succeeds('osctl ct exec mounttransition grep -Fx predecessor-mount-data /root/upgrade-mount')
                        machine.succeeds('rm -f /tank/hook/ct/mounttransition/pre-mount')
                        machine.succeeds('osctl ct restart mounttransition')
                        machine.wait_until_succeeds('osctl ct exec mounttransition grep -Fx predecessor-mount-data /root/upgrade-mount', timeout: 90)
                        machine.all_succeed('osctl ct stop mounttransition', 'osctl ct del -f --prune mounttransition')
                      ensure
                        mount_error = $!
                        begin
                          machine.execute('touch /overlap-pre-mount.release', timeout: 30)
                          if mount_error
                            machine.execute(<<~SH, timeout: 30)
                              for part in pid status log started release; do
                                file=/overlap-pre-mount.$part
                                echo "===== $file ====="
                                if test -f "$file"; then tail -c 8192 "$file"; fi
                              done
                              if test -s /overlap-pre-mount.pid; then
                                ps -p "$(cat /overlap-pre-mount.pid)" -o pid,ppid,state,args || true
                              fi
                              for part in pid status log; do
                                file=/overlap-management-switch.$part
                                echo "===== $file ====="
                                if test -f "$file"; then tail -c 8192 "$file"; fi
                              done
                            SH
                          end
                        rescue StandardError => diagnostic_error
                          warn "Unable to retain pre-mount overlap diagnostics: #{diagnostic_error}"
                        end
                      end
                    ''
                  else
                    ""
                }

                ${
                  if frozenActivation then
                    ''
                      assert_frozen.call('target activation')
                    ''
                  else
                    ""
                }

                ${
                  if nestedDocker then
                    ''
                      # Fresh Docker success alone cannot prove that the live
                      # nested PID and its writable-layer data survived the
                      # predecessor-to-target host userspace transition.
                      machine.wait_until_succeeds('osctl ct exec nesteddocker docker exec inherited grep -Fx inherited-nested-data /root/upgrade-data', timeout: 120)
                      expect(machine.osctl_json('ct show nesteddocker').fetch('init_pid')).to eq(nested_init)
                      expect(machine.succeeds("awk '{print $22}' /proc/#{nested_init}/stat")[1].strip).to eq(nested_init_start)
                      expect(machine.succeeds('osctl ct exec nesteddocker docker inspect -f "{{.Id}} {{.State.Pid}}" inherited')[1].strip).to eq(nested_identity)
                      machine.succeeds('osctl ct exec nesteddocker systemctl is-active docker.service')
                      _, nested_new = machine.succeeds(%(osctl ct exec nesteddocker docker run --rm --network none --memory 64m alpine:latest sh -c 'cat /sys/fs/cgroup/memory.max; echo post-upgrade-nested'), timeout: 180)
                      expect(nested_new.lines.map(&:strip)).to include('67108864', 'post-upgrade-nested')
                    ''
                  else
                    ""
                }

                ${
                  if nestedPodman then
                    ''
                      # A fresh post-switch Podman launch is not proof that
                      # the live predecessor-created nested PID survived.
                      machine.wait_until_succeeds('osctl ct exec nestedpodman podman exec inherited grep -Fx inherited-podman-data /root/upgrade-data', timeout: 120)
                      expect(machine.osctl_json('ct show nestedpodman').fetch('init_pid')).to eq(podman_init)
                      expect(machine.succeeds("awk '{print $22}' /proc/#{podman_init}/stat")[1].strip).to eq(podman_init_start)
                      expect(machine.succeeds('osctl ct exec nestedpodman podman inspect -f "{{.Id}} {{.State.Pid}}" inherited')[1].strip).to eq(podman_identity)
                      machine.succeeds('osctl ct exec nestedpodman podman info')
                      _, podman_new = machine.succeeds(%(osctl ct exec nestedpodman podman run --rm --network none --memory 64m docker.io/library/alpine:latest sh -c 'cat /sys/fs/cgroup$(cut -d: -f3 /proc/self/cgroup)/memory.max; echo post-upgrade-podman'), timeout: 180)
                      expect(podman_new.lines.map(&:strip)).to include('67108864', 'post-upgrade-podman')
                    ''
                  else
                    ""
                }

                ${
                  if nestedIncus then
                    ''
                      # An existing nested guest must keep its outer-guest
                      # process identity, not merely restart from saved data.
                      machine.wait_until_succeeds('osctl ct exec nestedincus incus exec inherited -- grep -Fx predecessor-incus-data /root/upgrade-data', timeout: 300)
                      expect(machine.osctl_json('ct show nestedincus').fetch('init_pid')).to eq(incus_host_init)
                      expect(machine.succeeds("awk '{print $22}' /proc/#{incus_host_init}/stat")[1].strip).to eq(incus_host_start)
                      incus_after = machine.succeeds('osctl ct exec nestedincus incus info inherited')[1]
                      expect(incus_after).to include('Status: RUNNING', 'Type: container')
                      expect(Integer(incus_after[/^PID:\s*(\d+)\s*$/, 1], 10)).to eq(incus_guest_pid)
                      expect(machine.succeeds("osctl ct exec nestedincus awk '{print $22}' /proc/#{incus_guest_pid}/stat")[1].strip).to eq(incus_guest_start)
                      init_nested_incus.call('postupgrade')
                      start_nested_incus.call('postupgrade')
                      machine.wait_until_succeeds('osctl ct exec nestedincus incus exec postupgrade -- true', timeout: 300)
                    ''
                  else
                    ""
                }

                ${
                  if overlapActivation then
                    ''
                      machine.wait_until_succeeds('test -s /overlap-exec.status', timeout: 240)
                      machine.wait_until_succeeds('test -s /overlap-runscript.status', timeout: 240)
                      machine.wait_until_succeeds('test -s /overlap-client.status', timeout: 240)
                      machine.succeeds('grep -Fx 0 /overlap-client.status')
                      machine.wait_until_succeeds('! kill -0 $(cat /overlap-client.pid) 2>/dev/null', timeout: 60)
                      [['exec', 'upgrade1'], ['runscript', 'upgrade2']].each do |kind, ctid|
                        status = Integer(machine.succeeds("cat /overlap-#{kind}.status")[1].strip, 10)
                        if status.zero?
                          machine.succeeds("osctl ct exec #{ctid} grep -Fx overlap-#{kind}-done /overlap-#{kind}")
                        else
                          expect(status).to eq(1), "#{kind}: unexpected activation outcome #{status}"
                          machine.succeeds("grep -E '(^|: )osctld closed connection$' /overlap-#{kind}.log")
                        end
                      end
                      machine.wait_until_succeeds("! ps -eo args= | grep -E '^osctld: tank:upgrade[12] runner:'", timeout: 60)
                      machine.succeeds("osctl ct exec upgrade1 grep -Fx retained-data /upgrade/data")
                      ensure
                        if $!
                          begin
                            machine.execute(<<~DIAGNOSTICS, timeout: 30)
                              for kind in client exec runscript; do
                                for part in pid status log; do
                                  file=/overlap-$kind.$part
                                  echo "===== $file ====="
                                  if test -f "$file"; then tail -c 8192 "$file"; fi
                                done
                                if test -s /overlap-$kind.pid; then
                                  ps -p "$(cat /overlap-$kind.pid)" -o pid,ppid,state,args || true
                                fi
                              done
                            DIAGNOSTICS
                          rescue StandardError => diagnostic_error
                            warn "Unable to retain activation overlap diagnostics: #{diagnostic_error}"
                          end
                        end
                      end
                    ''
                  else
                    ""
                }

                ${
                  if transferAcrossActivation then
                    ''
                      # Stream data contains the ACL, but this export does not
                      # transport dataset properties. Enable destination ACLs
                      # before receive, as in the repository transport fixture.
                      machine.succeeds('osctl ct import --as-id transfernew --zfs-property acltype=posixacl /root/upgrade-transfer.tar', timeout: 300)
                      machine.succeeds('osctl ct mount transfernew')
                      transfer_root = machine.osctl_json('ct show transfernew').fetch('rootfs')
                      machine.all_succeed(
                        "test \"$(cat #{transfer_root}/upgrade-transfer/plain)\" = predecessor-data",
                        "test \"$(stat -c '%u:%g:%a' #{transfer_root}/upgrade-transfer/plain)\" = '1234:5678:640'",
                        "test \"$(${pkgs.attr}/bin/getfattr --only-values -n user.delivery #{transfer_root}/upgrade-transfer/plain)\" = predecessor",
                        "${pkgs.acl}/bin/getfacl -n -p #{transfer_root}/upgrade-transfer/acl | grep -E '^user:4321:rwx$'",
                        "${pkgs.libcap}/bin/getcap #{transfer_root}/upgrade-transfer/filecap | grep -F 'cap_chown=ep'",
                        "sha256sum #{transfer_root}/upgrade-transfer/blob | awk '{print $1}' | cmp - /root/upgrade-transfer.sha",
                        'osctl ct start transfernew',
                        'osctl ct exec transfernew true',
                        'osctl ct stop transfernew',
                        'osctl ct del --prune transfernew',
                      )
                    ''
                  else
                    ""
                }

                ${
                  if activatedSystem == null then
                    ""
                  else
                    ''
                      create_workload.call('activegeneration', '192.0.2.13', create: false)
                      machine.succeeds('osctl ct exec activegeneration grep -Fx activated-generation-data /activated-generation-data')
                      assert_retained.call
                    ''
                }

                # Reusing a private hierarchy must be idempotent after restrictions
                # have settled, not just during the first daemon startup.
                private_mounts = lambda do
                  pid = daemon_identity.call.first
                  machine.succeeds("awk 'index($5, \"/run/osctl/cgroup\") == 1 || index($5, \"/run/osctl/bpf\") == 1 {print}' /proc/#{pid}/mountinfo")[1]
                end
                adopted_mounts = private_mounts.call
                expect(adopted_mounts).not_to be_empty
                2.times do
                  machine.succeeds('${nextSystem}/bin/switch-to-configuration test', timeout: 300)
                  machine.wait_for_osctl_pool('tank')
                  expect(private_mounts.call).to eq(adopted_mounts)
                  assert_retained.call
                  ${if frozenActivation then "assert_frozen.call('target reactivation')" else ""}
                  ${
                    if inheritedRecoveryTaint then
                      ''
                        expect(machine.osctl_json('ct show inheritedtaint').fetch('recovery_tainted')).to be(true)
                        machine.fails('osctl ct start inheritedtaint')
                      ''
                    else
                      ""
                  }
                end

                %w[graceful abrupt].each do |mode|
                  prior_daemon = daemon_identity.call
                  if mode == 'graceful'
                    machine.succeeds('sv -w 90 restart osctld', timeout: 120)
                  else
                    machine.succeeds("kill -KILL #{prior_daemon.first}")
                    machine.wait_until_succeeds("! kill -0 #{prior_daemon.first}")
                  end
                  machine.wait_for_service('osctld')
                  machine.wait_until_succeeds("pgrep -f '^osctld: main$'")
                  machine.wait_for_osctl_pool('tank')
                  expect(daemon_identity.call).not_to eq(prior_daemon)
                  expect(private_mounts.call).to eq(adopted_mounts)
                  assert_retained.call
                  ${if frozenActivation then "assert_frozen.call(\"#{mode} daemon restart\")" else ""}
                end

                ${
                  if frozenActivation then
                    ''
                      machine.succeeds('osctl ct unfreeze inheritedfrozen')
                      machine.wait_until_succeeds('test "$(osctl ct show -H -o state inheritedfrozen)" = running', timeout: 90)
                      machine.succeeds('osctl ct exec inheritedfrozen grep -Fx predecessor-frozen /root/frozen-data')
                      machine.all_succeed('osctl ct stop inheritedfrozen', 'osctl ct del --prune inheritedfrozen')
                    ''
                  else
                    ""
                }

                guest_snapshots.each do |ctid, saved|
                  if saved.fetch(:distribution) == 'fedora'
                    # Hand DNS management to the guest's own resolver manager now that the
                    # switched-to userspace is the product under test: drop the line the image
                    # ships and let NetworkManager own /etc/resolv.conf. The configured resolver
                    # must still become visible through the live-apply contract, which installs
                    # the host-side guard (etc/NetworkManager/conf.d/10-osctl-dns.conf) and
                    # refreshes the guest's resolver manager, so apply it once after the mutation.
                    machine.all_succeed(
                      "osctl ct exec #{ctid} sed -i '/^dns=none$/d' /etc/NetworkManager/conf.d/vpsadminos.conf",
                      "osctl ct exec #{ctid} nmcli general reload conf,dns-rc",
                      "osctl ct exec #{ctid} nmcli connection modify eth0 ipv4.dns 10.0.2.3 ipv4.ignore-auto-dns yes",
                      "osctl ct exec #{ctid} nmcli device reapply eth0",
                    )
                    machine.succeeds("osctl ct set dns-resolver #{ctid} 192.0.2.53")
                    # Configured resolver intent must survive an actual guest refresh,
                    # not just an unchanged file immediately after host activation.
                    machine.succeeds("osctl ct exec #{ctid} nmcli general reload dns-rc")
                    machine.succeeds("osctl ct exec #{ctid} grep -Fx 'nameserver 192.0.2.53' /etc/resolv.conf")
                  end
                  if saved.fetch(:distribution) == 'fedora'
                    # A failed live daemon-version query must not commit new DNS intent.
                    # Restore the guest executable even if an assertion fails.
                    nmcli_mode = machine.succeeds("osctl ct exec #{ctid} stat -c %a /usr/bin/nmcli")[1].strip
                    begin
                      machine.succeeds("osctl ct exec #{ctid} chmod a-x /usr/bin/nmcli")
                      machine.fails("osctl ct exec #{ctid} nmcli -t -f VERSION general")
                      machine.fails("osctl ct set dns-resolver #{ctid} 192.0.2.54")
                      expect(machine.osctl_json("ct show #{ctid}").fetch('dns_resolvers')).to eq(['192.0.2.53'])
                      machine.succeeds("osctl ct exec #{ctid} grep -Fx 'nameserver 192.0.2.53' /etc/resolv.conf")
                    ensure
                      machine.succeeds("osctl ct exec #{ctid} chmod #{nmcli_mode} /usr/bin/nmcli")
                    end

                    # Exit 8 while NetworkManager is stopped is not a failed apply:
                    # keep the new configured intent for its next normal start.
                    machine.succeeds("osctl ct exec #{ctid} systemctl stop NetworkManager.service")
                    begin
                      machine.fails("osctl ct exec #{ctid} systemctl is-active NetworkManager.service")
                      machine.succeeds("osctl ct set dns-resolver #{ctid} 192.0.2.54")
                      expect(machine.osctl_json("ct show #{ctid}").fetch('dns_resolvers')).to eq(['192.0.2.54'])
                    ensure
                      machine.succeeds("osctl ct exec #{ctid} systemctl start NetworkManager.service")
                    end
                    machine.succeeds("osctl ct exec #{ctid} nmcli general reload dns-rc")
                  end
                  machine.succeeds("osctl ct set dns-resolver #{ctid} 192.0.2.54")
                  machine.succeeds("osctl ct exec #{ctid} nmcli general reload dns-rc") if saved.fetch(:distribution) == 'fedora'
                  machine.succeeds("osctl ct exec #{ctid} grep -Fx 'nameserver 192.0.2.54' /etc/resolv.conf")
                  machine.succeeds("osctl ct unset dns-resolver #{ctid}")
                  expect(machine.osctl_json("ct show #{ctid}").fetch('dns_resolvers')).to be_nil
                  if saved.fetch(:distribution) == 'fedora'
                    machine.succeeds("osctl ct exec #{ctid} nmcli general reload dns-rc")
                    machine.succeeds("osctl ct exec #{ctid} grep -Fx 'nameserver 10.0.2.3' /etc/resolv.conf")
                    machine.fails("osctl ct exec #{ctid} test -e /etc/NetworkManager/conf.d/10-osctl-dns.conf")
                  end
                  machine.succeeds("osctl ct set dns-resolver #{ctid} 192.0.2.53")
                end
                assert_retained.call

                ${
                  if reverseActivation then
                    ''
                      # Row 9 — rollback→forward. The guests above carry a managed
                      # resolver set by the newer daemon, which is the documented
                      # downgrade-consideration state. Activate the booted
                      # predecessor userspace again and require the workload, the
                      # guest-visible DNS policy and the newer daemon's owned guard
                      # drop-in to survive as documented (the older daemon cannot
                      # remove a drop-in it does not own), then return to the
                      # target and require the newer daemon to still own and clean
                      # up that state. The predecessor daemon cannot be assumed to
                      # expose the newer daemon's resolver introspection, so this
                      # leg asserts the guest-visible policy and retained workload
                      # directly instead of reusing assert_retained.
                      prior_daemon = daemon_identity.call
                      sequences = snapshots.transform_values do |saved|
                        JSON.parse(machine.succeeds("cat #{saved.fetch(:stream_prefix)}.progress")[1]).fetch('sequence')
                      end
                      machine.succeeds("#{booted_system}/bin/switch-to-configuration test", timeout: 300)
                      # Keep the same connections transferring ordered data during
                      # the reverse activation too.
                      snapshots.each do |ctid, saved|
                        prefix = saved.fetch(:stream_prefix)
                        machine.succeeds("test ! -e #{prefix}.error")
                        stream = JSON.parse(machine.succeeds("cat #{prefix}.progress")[1])
                        expect(stream.fetch('sequence')).to be > sequences.fetch(ctid)
                        expect(stream.fetch('port')).to eq(saved.fetch(:stream_port))
                      end
                      machine.wait_for_osctl_pool('tank')
                      expect(machine.succeeds('uname -r')[1].strip).to eq(before_kernel)
                      expect(machine.succeeds('cat /proc/sys/kernel/random/boot_id')[1].strip).to eq(before_boot)
                      expect(machine.succeeds('readlink -f /run/booted-system')[1].strip).to eq(booted_system)
                      expect(machine.succeeds('readlink -f /run/current-system')[1].strip).to eq(booted_system)
                      expect(daemon_identity.call).not_to eq(prior_daemon)
                      guest_snapshots.each do |ctid, saved|
                        assert_guest_ready(machine, ctid)
                        machine.succeeds("osctl ct exec #{ctid} grep -Fx 'nameserver 192.0.2.53' /etc/resolv.conf")
                        if saved.fetch(:distribution) == 'fedora'
                          machine.succeeds("osctl ct exec #{ctid} test -e /etc/NetworkManager/conf.d/10-osctl-dns.conf")
                        end
                        marker = saved.fetch(:impermanent) ? '/persistent/upgrade-retained' : '/root/upgrade-retained'
                        machine.succeeds("osctl ct exec #{ctid} grep -Fx inherited-persistent #{marker}")
                      end
                      activate_generation.call('${nextSystem}')
                      # The inherited bpffs mount must survive the entire
                      # downgrade→upgrade round trip, not only the first upgrade.
                      expect(machine.succeeds('stat -c %d:%i /run/osctl/bpf')[1].strip).to eq(before_bpffs)
                      expect(machine.succeeds('stat -f -c %T /run/osctl/bpf')[1].strip).to eq('bpf_fs')
                      guest_snapshots.each do |ctid, saved|
                        expect(machine.osctl_json("ct show #{ctid}").fetch('dns_resolvers')).to eq(['192.0.2.53'])
                        machine.succeeds("osctl ct unset dns-resolver #{ctid}")
                        expect(machine.osctl_json("ct show #{ctid}").fetch('dns_resolvers')).to be_nil
                        if saved.fetch(:distribution) == 'fedora'
                          machine.succeeds("osctl ct exec #{ctid} nmcli general reload dns-rc")
                          machine.succeeds("osctl ct exec #{ctid} grep -Fx 'nameserver 10.0.2.3' /etc/resolv.conf")
                          machine.fails("osctl ct exec #{ctid} test -e /etc/NetworkManager/conf.d/10-osctl-dns.conf")
                        end
                        # Leave the managed resolver set again: the sections after
                        # this one assert it as the durable configured intent.
                        machine.succeeds("osctl ct set dns-resolver #{ctid} 192.0.2.53")
                      end
                    ''
                  else
                    ""
                }

                # Running helpers on inherited CTs have different contracts: attach
                # and runscript enter the guest, while ct su is an unprivileged host
                # shell for this CT. Do not count one path as proof of the others.
                machine.succeeds('echo host-shell > /run/upgrade-host-only; chmod 444 /run/upgrade-host-only')
                snapshots.each_key do |ctid|
                  verify_helper_mounts = lambda do |operation|
                    before = snapshots.fetch(ctid).fetch(:mounts)
                    after = machine.succeeds("cat /proc/#{snapshots.fetch(ctid).fetch(:init)}/mountinfo")[1]
                    expect_mounts_unchanged.call("#{operation} changed inherited #{ctid} mounts", before, after)
                  end
                  attach = 'set -e; test "$(id -u)" = 0; test ! -e /run/upgrade-host-only; grep -Fx retained-data /upgrade/data; exit 0'
                  machine.succeeds("printf '%s\\n' #{Shellwords.escape(attach)} | timeout 30 osctl ct attach #{ctid}", timeout: 60)
                  verify_helper_mounts.call('ct attach')
                  su = 'set -e; test "$(id -u)" != 0; grep -Fx host-shell /run/upgrade-host-only; test -z "$OSCTL_RUN_ID"; exit 0'
                  machine.succeeds("printf '%s\\n' #{Shellwords.escape(su)} | timeout 30 osctl ct su #{ctid}", timeout: 60)
                  verify_helper_mounts.call('ct su')
                  script = "#!/bin/sh\nset -eu\ntest \"$(id -u)\" = 0\ngrep -Fx retained-data /upgrade/data\necho helper-data > /upgrade/helper-data\n"
                  machine.succeeds("printf %s #{Shellwords.escape(script)} | timeout 30 osctl ct runscript #{ctid} -", timeout: 60)
                  verify_helper_mounts.call('ct runscript')
                  expect(machine.succeeds("osctl ct cat #{ctid} /upgrade/helper-data")[1].strip).to eq('helper-data')
                  verify_helper_mounts.call('ct cat')
                end
                assert_retained.call

                assert_limits.call(25, 64)
                machine.all_succeed(
                  'osctl ct set cpu-limit limited 50',
                  "osctl ct cgparams set -v #{cgroup_version} limited pids.max 48",
                  "osctl ct cgparams set -v #{cgroup_version} limited cpuset.cpus 1",
                  'osctl ct set memory-limit limited 167772160 0',
                  'osctl ct devices chmod limited char 1 5 rwm',
                  'osctl ct exec limited dd if=/dev/null of=/dev/zero bs=1 count=0',
                  'osctl ct devices chmod limited char 1 5 r',
                )
                assert_limits.call(50, 48, 167772160, '1')
                inherited_bpf = bpf_identity.call

                # Mutating this inherited bind must not propagate into either sibling
                # or alter the host source mount. Re-adding it also tests live mapping.
                source_mount = machine.succeeds('findmnt -n -o ID,TARGET,SOURCE -T /tank/upgrade-bind')[1]
                2.times do
                  machine.succeeds('osctl ct mounts deactivate limited /mnt/inherited')
                  machine.fails('osctl ct exec limited test -e /mnt/inherited/marker')
                  machine.succeeds('osctl ct mounts activate limited /mnt/inherited')
                  machine.succeeds('osctl ct exec limited grep -Fx inherited-bind /mnt/inherited/marker')
                  machine.succeeds('osctl ct mounts del limited /mnt/inherited')
                  machine.fails('osctl ct exec limited test -e /mnt/inherited/marker')
                  machine.succeeds('osctl ct mounts new --fs /tank/upgrade-bind --type bind --opts bind,create=dir --mountpoint /mnt/inherited limited')
                  machine.succeeds("osctl ct exec limited sh -c 'echo guest-owned > /mnt/inherited/guest-marker; test \"$(stat -c %u:%g /mnt/inherited/guest-marker)\" = 0:0'")
                  snapshots.each_key do |ctid|
                    machine.fails("osctl ct exec #{ctid} test -e /mnt/inherited/marker")
                  end
                  expect(machine.succeeds('findmnt -n -o ID,TARGET,SOURCE -T /tank/upgrade-bind')[1]).to eq(source_mount)
                  assert_retained.call
                end
                machine.succeeds('osctl ct restart limited')
                machine.wait_until_succeeds('osctl ct exec limited rc-service syslog status')
                limited_init = machine.osctl_json('ct show limited').fetch('init_pid')
                limited_identity = machine.succeeds("awk '{print $22}' /proc/#{limited_init}/stat")[1]
                machine.succeeds('osctl ct exec limited grep -Fx guest-owned /mnt/inherited/guest-marker')
                assert_limits.call(50, 48, 167772160, '1')
                machine.all_succeed('osctl ct stop limited', 'osctl ct del --prune limited')
                machine.succeeds("test ! -e /run/osctl/cgroup/#{cgroup_base}") if cgroup_version == 2
                machine.succeeds("test -z \"$(find /run/osctl/bpf/osctl/pools/tank/links -name '*limited*')\"") if cgroup_version == 2

                # The transient attach path must work on an inherited stopped CT,
                # without starting it or losing its persistent root filesystem.
                machine.all_succeed(
                  'osctl ct exec -rn previouslyrun ping -c 1 255.255.255.254',
                  'osctl ct runscript -rn previouslyrun /root/upgrade-stopped-network',
                  'osctl ct exec -r previouslyrun grep -Fx stopped-runscript-data /root/stopped-runscript',
                )
                expect(machine.osctl_json('ct show previouslyrun').fetch('state')).to eq('stopped')
                %w[neverstarted mountedstopped previouslyrun].each_with_index do |ctid, index|
                  expect(machine.osctl_json("ct show #{ctid}").fetch('state')).to eq('stopped')
                  machine.succeeds("osctl ct start #{ctid}")
                  machine.wait_until_succeeds("osctl ct exec #{ctid} rc-service networking status")
                  machine.wait_until_succeeds("ping -c 1 192.0.2.#{20 + index}")
                  if ctid == 'mountedstopped'
                    machine.succeeds('osctl ct exec mountedstopped grep -Fx mounted-data /mounted-data')
                  elsif ctid == 'previouslyrun'
                    machine.succeeds('osctl ct exec previouslyrun grep -Fx predecessor-data /root/retained')
                  end
                  machine.succeeds("osctl ct restart #{ctid}")
                  machine.wait_until_succeeds("osctl ct exec #{ctid} rc-service networking status")
                  machine.wait_until_succeeds("ping -c 1 192.0.2.#{20 + index}")
                  machine.all_succeed("osctl ct stop #{ctid}", "osctl ct del --prune #{ctid}")
                end

                # New userspace must start ordinary guests on the still-running
                # predecessor kernel too, including 6.12 without the optional new
                # tracing/securityfs sources and 6.18 with them already present.
                machine.all_succeed(
                  "osctl ct new --distribution alpine afterupgrade",
                  "osctl ct unset start-menu afterupgrade",
                  "osctl ct netif new routed afterupgrade eth0",
                  "osctl ct netif ip add afterupgrade eth0 192.0.2.12/32",
                  "osctl ct start afterupgrade",
                )
                machine.wait_until_succeeds("osctl ct exec afterupgrade rc-service networking status")
                machine.wait_until_succeeds("ping -c 1 192.0.2.12")
                machine.all_succeed(
                  "osctl ct exec afterupgrade sh -c 'echo post-upgrade-data > /root/retained'",
                  "osctl ct restart afterupgrade",
                )
                machine.wait_until_succeeds("osctl ct exec afterupgrade rc-service networking status")
                machine.wait_until_succeeds("ping -c 1 192.0.2.12")
                machine.all_succeed(
                  "osctl ct exec afterupgrade grep -Fx post-upgrade-data /root/retained",
                  "osctl ct stop afterupgrade",
                  "osctl ct del --prune afterupgrade",
                )
                expect(machine.succeeds('uname -r')[1].strip).to eq(before_kernel)
                expect(machine.succeeds('cat /proc/sys/kernel/random/boot_id')[1].strip).to eq(before_boot)

                # Restart the actual predecessor-created running workloads, not only
                # afterupgrade. Convert their test init back to the ordinary guest init.
                snapshots.each do |ctid, saved|
                  prefix = saved.fetch(:stream_prefix)
                  machine.succeeds("touch #{prefix}.stop")
                  machine.wait_until_succeeds("test -s #{prefix}.done")
                  machine.succeeds("test ! -e #{prefix}.error")
                  machine.all_succeed("osctl ct stop #{ctid}", "osctl ct unset init-cmd #{ctid}", "osctl ct start #{ctid}")
                  machine.wait_until_succeeds("osctl ct exec #{ctid} rc-service networking status")
                  machine.wait_until_succeeds("ping -c 1 #{saved.fetch(:address)}")
                  machine.succeeds("osctl ct exec #{ctid} grep -Fx retained-data /upgrade/data")
                  machine.succeeds("osctl ct restart #{ctid}")
                  machine.wait_until_succeeds("osctl ct exec #{ctid} rc-service networking status")
                  machine.wait_until_succeeds("ping -c 1 #{saved.fetch(:address)}")
                  machine.succeeds("osctl ct exec #{ctid} grep -Fx retained-data /upgrade/data")
                end

                # Exercise the guest's own reboot command, not another host stop/start.
                # The old host kernel and boot generation must not change with it.
                snapshots.each do |ctid, saved|
                  old_init = machine.osctl_json("ct show #{ctid}").fetch('init_pid')
                  old_identity = machine.succeeds("awk '{print $22}' /proc/#{old_init}/stat")[1].strip
                  machine.succeeds("osctl ct exec #{ctid} sh -c '(sleep 2; reboot) >/root/upgrade-reboot.log 2>&1 </dev/null &'")
                  machine.wait_until_succeeds("test ! -e /proc/#{old_init}/stat || test \"$(awk '{print $22}' /proc/#{old_init}/stat)\" != #{old_identity}", timeout: 120)
                  machine.wait_until_succeeds("osctl ct exec #{ctid} rc-service networking status", timeout: 180)
                  machine.wait_until_succeeds("ping -c 1 #{saved.fetch(:address)}")
                  info = machine.osctl_json("ct show #{ctid}")
                  expect(info.fetch('state')).to eq('running')
                  new_identity = machine.succeeds("awk '{print $22}' /proc/#{info.fetch('init_pid')}/stat")[1].strip
                  expect([info.fetch('init_pid'), new_identity]).not_to eq([old_init, old_identity])
                  machine.succeeds("osctl ct exec #{ctid} grep -Fx retained-data /upgrade/data")
                  expect(info.fetch('recovery_tainted')).to be(false)
                  expect(machine.succeeds('uname -r')[1].strip).to eq(before_kernel)
                  expect(machine.succeeds('cat /proc/sys/kernel/random/boot_id')[1].strip).to eq(before_boot)
                end

                guest_snapshots.each do |ctid, saved|
                  machine.succeeds("osctl ct restart #{ctid}")
                  machine.wait_until_succeeds("ping -c 1 #{saved.fetch(:address)}")
                  assert_guest_ready(machine, ctid)
                  # The configured resolver must survive the restart on the host side - that is the
                  # durable part of the contract, and it is what the restart is meant to exercise.
                  # Guest visibility is the observable of a live application for these pinned guests:
                  # their own resolver tooling (NetworkManager on fedora, resolvconf/systemd-resolved
                  # on the NixOS images pinned by older predecessors) regenerates /etc/resolv.conf
                  # from the image's networking.nameservers when the network comes up, and the series
                  # guards that only for NetworkManager guests. Re-apply and then require the exact
                  # line, as assert_retained and the resolver verification above do.
                  expect(machine.osctl_json("ct show #{ctid}").fetch('dns_resolvers')).to eq(['192.0.2.53'])
                  machine.succeeds("osctl ct set dns-resolver #{ctid} 192.0.2.53")
                  machine.succeeds("osctl ct exec #{ctid} grep -Fx 'nameserver 192.0.2.53' /etc/resolv.conf")
                  marker = saved.fetch(:impermanent) ? '/persistent/upgrade-retained' : '/root/upgrade-retained'
                  machine.succeeds("osctl ct exec #{ctid} grep -Fx inherited-persistent #{marker}")
                  if saved.fetch(:impermanent)
                    machine.succeeds("osctl ct exec #{ctid} test ! -e /upgrade-ephemeral")
                    expect(machine.osctl_json("ct show #{ctid}").fetch('boot_dataset')).not_to eq(saved.fetch(:boot_dataset))
                    machine.wait_until_succeeds("! zfs list -H #{Shellwords.escape(saved.fetch(:boot_dataset))}", timeout: 120)
                  end
                  if saved.fetch(:generation)
                    expect(machine.succeeds("osctl ct exec #{ctid} readlink /run/current-system")[1]).to eq(saved.fetch(:generation))
                  end
                  machine.all_succeed("osctl ct stop #{ctid}", "osctl ct del --prune #{ctid}")
                end

                capture_upgrade_access_trace(machine)
                # Containers created by the predecessor must still stop and delete cleanly.
                snapshots.each do |ctid, saved|
                  machine.all_succeed(
                    "osctl ct stop #{ctid}",
                    "test ! -e /sys/class/net/#{saved.fetch(:veth)}",
                  )
                  info = machine.osctl_json("ct show #{ctid}")
                  expect(info.fetch('state')).to eq('stopped')
                  expect(info.fetch('recovery_tainted')).to be(false)
                  machine.succeeds("osctl ct del --prune #{ctid}")
                end
                ${
                  if inheritedRecoveryTaint then
                    ''
                      # The new daemon must not erase the predecessor's taint or
                      # remove an unrelated replacement link on failed cleanup.
                      machine.succeeds("ip link add #{taint_veth} type dummy")
                      replacement_index = machine.succeeds("cat /sys/class/net/#{taint_veth}/ifindex")[1].strip
                      machine.fails('osctl ct recover forget-host-link inheritedtaint eth0')
                      expect(machine.succeeds("cat /sys/class/net/#{taint_veth}/ifindex")[1].strip).to eq(replacement_index)
                      machine.fails('osctl ct recover cleanup inheritedtaint')
                      expect(machine.osctl_json('ct show inheritedtaint').fetch('recovery_tainted')).to be(true)
                      machine.succeeds("ip link delete #{taint_veth}")
                      machine.succeeds('osctl ct recover forget-host-link inheritedtaint eth0')
                      expect(machine.osctl_json('ct show inheritedtaint').fetch('recovery_tainted')).to be(true)
                      machine.succeeds('osctl ct recover cleanup inheritedtaint')
                      expect(machine.osctl_json('ct show inheritedtaint').fetch('recovery_tainted')).to be(false)
                      machine.succeeds('osctl ct start inheritedtaint')
                      machine.wait_until_succeeds('osctl ct exec inheritedtaint true', timeout: 90)
                      machine.succeeds('osctl ct del -f --prune inheritedtaint')
                    ''
                  else
                    ""
                }
      '';
    }
  )
  (
    (builtins.removeAttrs args [
      "cgroupVersion"
      "guestPolicies"
      "reverseActivation"
      "overlapActivation"
      "managementActivation"
      "mountingActivation"
      "nestedDocker"
      "nestedPodman"
      "nestedIncus"
      "frozenActivation"
      "transferAcrossActivation"
      "inheritedRecoveryTaint"
    ])
    // {
      inherit system;
      pkgs = previous.inputs.nixpkgs.outPath;
      testFramework = previous.lib.testFramework;
      configuration =
        if configuration == null then null else import (previous.outPath + "/${configuration}");
    }
  )
