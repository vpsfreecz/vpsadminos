let
  partialInitExample = "releases a server after post-publication RPC auth setup fails";
  legacyNlmExample = "shuts down a legacy server before the first NLM lock";
  exampleFilterEnv = builtins.getEnv "VPSADMINOS_NFS_CANCELLATION_EXAMPLE_FILTER";
  exampleFilter =
    if
      builtins.elem exampleFilterEnv [
        partialInitExample
        legacyNlmExample
      ]
    then
      exampleFilterEnv
    else
      "";
in
{
  pkgs,
  machine,
  name,
  description,
  expectedKernelRelease,
  expectedKernelRevision,
}:
let
  nfsRetryOptions = "timeo=300,retrans=2";
  utilLinux = pkgs.util-linux;
  kmod = pkgs.kmod;
  blockedNfsAuthModprobe = pkgs.writeShellScript "nfs-blocked-modprobe" ''
    set -eu
    printf '%s\n' "$*" >> /run/nfs-failed-modprobe-invocations
    if [ "$#" -ne 3 ] || [ "$1" != -q ] || [ "$2" != -- ] || [ "$3" != rpc-auth-gss-390003 ]; then
      printf '%s\n' "$*" > /run/nfs-failed-modprobe-rejected
      exit 1
    fi
    printf '%s\n' "$$" > /run/nfs-failed-modprobe-helper.pid
    printf '%s\n' "$3" > /run/nfs-failed-modprobe-request
    i=0
    while [ ! -e /run/nfs-failed-modprobe-release ] && [ "$i" -lt 300 ]; do
      ${pkgs.coreutils}/bin/sleep 0.1
      i=$((i + 1))
    done
    exit 1
  '';
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
    mount -t nfs -o "vers=$1,proto=tcp,${nfsRetryOptions},nolock" \
      10.0.0.10:/srv/nfs-cancellation /mnt/nfs
    exec /sbin/nfs-dirty-init-program "/mnt/nfs/dirty-init-$1"
  '';
  shutdownUnmountProgram = pkgs.pkgsStatic.stdenv.mkDerivation {
    name = "nfs-shutdown-unmount";
    src = ./nfs-cancellation;
    dontConfigure = true;
    buildPhase = ''
      "$CC" -std=gnu11 -O2 -Wall -Wextra -Werror \
        -o shutdown-unmount shutdown-unmount.c
    '';
    installPhase = ''
      install -Dm755 shutdown-unmount "$out/bin/shutdown-unmount"
    '';
  };
  kernelRelease = expectedKernelRelease;
in
{
  inherit name description;
  tags = [ "ci" ];
  machine = machine // {
    modules = (machine.modules or [ ]) ++ [
      {
        system.extraDependencies = [
          utilLinux
          kmod
          blockedNfsAuthModprobe
        ];
      }
    ];
  };

  testScript = ''
    require 'shellwords'

    nfs_cancellation_example_filter = ${builtins.toJSON exampleFilter}
    unless nfs_cancellation_example_filter.empty?
      define_singleton_method(:it) do |message, pending: false, skip: false, &block|
        example(
          message,
          pending: pending,
          skip: skip || message != nfs_cancellation_example_filter,
          &block
        )
      end
    end

    before(:suite) do
      machine.start
      machine.wait_for_osctl_pool("tank")
      machine.wait_until_online
      # The suite name is not runtime proof of the configured kernel target.
      # Retain the actual release in the normal shell transcript as well.
      # The canonical stable fixture passes its exact selected release.
      machine.succeeds('test "$(uname -r)" = ${kernelRelease} && uname -r')
      machine.succeeds(
        'test -x ${utilLinux}/bin/nsenter && ' \
          'test -x ${utilLinux}/bin/unshare',
      )
      machine.succeeds(
        "grep -F '" \
          '"kernelSourceRevision":"${expectedKernelRevision}"' \
          "' /etc/vpsadminos/security-evidence.json",
      )
      machine.push_file(
        "${shutdownUnmountProgram}/bin/shutdown-unmount",
        '/run/nfs-shutdown-unmount',
        preserve: true,
      )
      # A port-selected gateway MAC makes stopping one container disrupt the
      # other client's TCP connection, independently of NFS cancellation.
      @nfs_bridge_mac = machine.succeeds(
        'test "$(cat /sys/class/net/lxcbr0/addr_assign_type)" = 3 && ' \
          'cat /sys/class/net/lxcbr0/address',
      )[1].strip

      nfs1_init_pid = nil
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
        if ct == 'nfs1'
          nfs1_init_pid = Integer(
            machine.succeeds("osctl ct show -H -o init_pid nfs1")[1].strip,
          )
          helpers_ready = machine.succeeds(
            "#{nfs_namespace_control(nfs1_init_pid, enter_mount: true)} " \
              "'mount --make-rslave /; mount -t sysfs sysfs /sys; " \
              "test -x /usr/bin/unshare; test -x /bin/sh; " \
              "test -r /proc/1/ns/mnt; test -r /proc/1/root; " \
              "test -x ./nfs-shutdown-unmount; " \
              "echo NFS_CONTAINER_NAMESPACE_HELPERS_READY'",
          )[1].strip
          expect(helpers_ready).to eq('NFS_CONTAINER_NAMESPACE_HELPERS_READY')
        end
        machine.all_succeed(
          "osctl ct exec #{ct} rc-update add rpcbind default",
          "osctl ct exec #{ct} rc-update add rpc.statd default",
          "osctl ct exec #{ct} rc-service rpcbind start",
          "osctl ct exec #{ct} rc-service rpc.statd start",
          "osctl ct exec #{ct} mkdir -p /mnt/nfs /mnt/nfs-again",
        )
      end

      cancellation_abi = machine.succeeds(
        "#{nfs_namespace_control(nfs1_init_pid)} " \
          "'mount --make-rslave /; mount -t sysfs sysfs /sys; " \
          "for control in shutdown shutdown_tree; do " \
          "test \"$(stat -c %a /sys/fs/nfs/net/nfs_client/$control)\" = 600; " \
          "test \"$(cat /sys/fs/nfs/net/nfs_client/$control)\" = 0; " \
          "done; echo NFS_CANCELLATION_ABI_READY'",
      )[1].strip
      expect(cancellation_abi).to eq('NFS_CANCELLATION_ABI_READY')

      machine.all_succeed(
        "mkdir -p /srv/nfs-cancellation /srv/nfs-cancellation-auth-null",
        "chmod 0777 /srv/nfs-cancellation /srv/nfs-cancellation-auth-null",
        "osctl-exportfs server new --address 10.0.0.10 " \
          "--nfs-versions 3,4,4.0,4.1,4.2 server1",
        "osctl-exportfs export add --directory /srv/nfs-cancellation " \
          "--host 192.168.1.0/24 --options fsid=1234,rw,no_root_squash server1",
        "osctl-exportfs export add --directory /srv/nfs-cancellation-auth-null " \
          "--host 192.168.1.0/24 " \
          "--options fsid=1235,rw,no_root_squash," \
          "sec=sys:krb5 server1",
        "osctl-exportfs server start server1",
      )
      machine.wait_until_succeeds("test -s /run/osctl/exportfs/servers/server1/pid")
      # NFSD implies enabled 4.0 from +4; it only prints disabled -4.0.
      machine.wait_until_succeeds(
        "${utilLinux}/bin/nsenter " \
          "-t $(cat /run/osctl/exportfs/servers/server1/pid) -m -n " \
          "cat /proc/fs/nfsd/versions | grep -Fx '+3 +4 +4.1 +4.2'",
      )
      machine.succeeds(
        "${utilLinux}/bin/nsenter " \
          "-t $(cat /run/osctl/exportfs/servers/server1/pid) -m -n " \
          "${utilLinux}/bin/unshare --mount true",
      )
    end

    def isolate_client(operation, reset: false)
      action = reset ? '-p tcp -j REJECT --reject-with tcp-reset' : '-j DROP'
      machine.all_succeed(
        "iptables -#{operation} FORWARD -s 192.168.1.21 -d 10.0.0.10 #{action}",
        "iptables -#{operation} FORWARD -s 10.0.0.10 -d 192.168.1.21 #{action}",
      )
    end

    def nfs_namespace_control(init_pid, enter_mount: false, trace: false)
      shell_options = trace ? '-exc' : '-ec'

      if enter_mount
        "PATH=/usr/sbin:/usr/bin:/sbin:/bin " \
          "${utilLinux}/bin/nsenter -t #{init_pid} " \
          "--user --setuid 0 --setgid 0 --keep-caps --net --mount " \
          "--root --wd=/run -- " \
          "/usr/bin/unshare --mount /bin/sh #{shell_options}"
      else
        "${utilLinux}/bin/nsenter -t #{init_pid} --net " \
          "${utilLinux}/bin/unshare --mount sh #{shell_options}"
      end
    end

    def nfs_namespace_path_control(netns)
      "${utilLinux}/bin/nsenter --net=#{netns} " \
        "${utilLinux}/bin/unshare --mount sh -ec"
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
          "-o vers=#{version},proto=tcp,${nfsRetryOptions} " \
          "10.0.0.10:/srv/nfs-cancellation #{path}",
      )
      # Do not request a retry mode: assert the selected kernel source policy.
      options = machine.succeeds("osctl ct exec #{ct} cat /proc/mounts")[1]
        .lines.find { |line| line.split[1] == path }.split[3].split(',')
      expect(options).to include('soft')
      expect(options).not_to include('hard', 'softerr')
    end

    def with_restored_nfs_client(version, before_restore: [])
      completed = false
      begin
        yield
        completed = true
      ensure
        # Try every restore step. Keep an original test failure primary, but
        # surface the first restore failure when the test body succeeded.
        cleanup_error = nil
        (before_restore + [
          [
            'stop',
            lambda do
              stop_nfs_client unless machine.succeeds(
                "osctl ct show -H -o state nfs1",
              )[1].strip == 'stopped'
            end,
          ],
          ['start', -> { machine.succeeds("osctl ct start nfs1", timeout: 60) }],
          ['remount', -> { mount_nfs('nfs1', version) }],
        ]).each do |operation, cleanup|
          begin
            cleanup.call
          rescue StandardError, RSpec::Expectations::ExpectationNotMetError => e
            cleanup_error ||= e
            warn "NFS client #{operation} cleanup failed: #{e.class}: #{e.message}"
          end
        end
        raise cleanup_error if completed && cleanup_error
      end
    end

    def transient_nfs_server_ids(init_pid)
      control = nfs_namespace_control(init_pid)
      output = machine.succeeds(
        "#{control} 'mount --make-rslave /; mount -t sysfs sysfs /sys; " \
          "find /sys/fs/nfs -mindepth 1 -maxdepth 1 -type d " \
          "-name \"server-*\" -printf \"%f\\n\" | sort'",
      )[1]
      output.lines(chomp: true).reject(&:empty?)
    end

    def failed_nfs_mount_result_command
      body =
        "printf 'NFS_FAILED_MOUNT_STATUS='; " \
        "if test -e /root/nfs-failed-mount-status; then " \
        "cat /root/nfs-failed-mount-status; else echo missing; fi; " \
        "echo NFS_FAILED_MOUNT_LOG_BEGIN; " \
        "if test -e /root/nfs-failed-mount.log; then " \
        "cat /root/nfs-failed-mount.log; else echo missing; fi; " \
        "echo NFS_FAILED_MOUNT_LOG_END"
      "osctl ct exec nfs1 sh -c #{Shellwords.escape(body)}"
    end

    def failed_nfs_mount_supervisor_command(
      mount_command:,
      pid_path: '/root/nfs-failed-mount.pid',
      status_path: '/root/nfs-failed-mount-status',
      log_path: '/root/nfs-failed-mount.log'
    )
      escaped_pid = Shellwords.escape(pid_path)
      escaped_status = Shellwords.escape(status_path)
      escaped_log = Shellwords.escape(log_path)
      "set +e; #{mount_command} >#{escaped_log} 2>&1 & " \
        "mount_pid=$!; printf '%s\\n' \"$mount_pid\" >#{escaped_pid}; " \
        "wait \"$mount_pid\"; status=$?; " \
        "printf '%s\\n' \"$status\" >#{escaped_status}"
    end

    def failed_nfs_mount_stop_body(
      pid_path: '/root/nfs-failed-mount.pid',
      status_path: '/root/nfs-failed-mount-status'
    )
      escaped_pid = Shellwords.escape(pid_path)
      escaped_status = Shellwords.escape(status_path)
      source = Shellwords.escape('10.0.0.10:/srv/nfs-cancellation-auth-null')
      target = Shellwords.escape('/mnt/nfs-failed')
      options = Shellwords.escape('sec=krb5,nolock,retry=0')
      "if test ! -s #{escaped_status}; then set -e; " \
        "test -s #{escaped_pid}; pid=$(cat #{escaped_pid}); " \
        "case \"$pid\" in \"\"|*[!0-9]*) exit 1;; esac; " \
        "cmdline=/proc/$pid/cmdline; test -r \"$cmdline\"; " \
        "tr '\\0' '\\n' < \"$cmdline\" | " \
        "grep -Eq '(^|/)mount[.]nfs$'; " \
        "tr '\\0' '\\n' < \"$cmdline\" | grep -Fxq #{source}; " \
        "tr '\\0' '\\n' < \"$cmdline\" | grep -Fxq #{target}; " \
        "tr '\\0' '\\n' < \"$cmdline\" | grep -Eq '(^|,)vers=3(,|$)'; " \
        "if tr '\\0' '\\n' < \"$cmdline\" | grep -Eq '(^|,)mountvers='; " \
        "then exit 1; fi; " \
        "tr '\\0' '\\n' < \"$cmdline\" | grep -Fq #{options}; " \
        "kill \"$pid\"; fi"
    end

    def failed_nfs_mount_supervisor_done_body(
      supervisor_pid_path: '/root/nfs-failed-mount-supervisor.pid',
      status_path: '/root/nfs-failed-mount-status'
    )
      escaped_supervisor = Shellwords.escape(supervisor_pid_path)
      escaped_status = Shellwords.escape(status_path)
      "set -e; test -s #{escaped_status}; test -s #{escaped_supervisor}; " \
        "supervisor=$(cat #{escaped_supervisor}); " \
        "case \"$supervisor\" in \"\"|*[!0-9]*) exit 1;; esac; " \
        "if kill -0 \"$supervisor\" 2>/dev/null; then exit 1; fi"
    end

    def failed_nfs_host_cleanup_body(
      helper_pid_path: '/run/nfs-failed-modprobe-helper.pid',
      control_paths: [
        '/run/nfs-failed-modprobe-request',
        '/run/nfs-failed-modprobe-release',
        '/run/nfs-failed-modprobe-invocations',
        '/run/nfs-failed-modprobe-rejected',
        '/run/nfs-failed-modprobe-helper.pid'
      ]
    )
      escaped_helper_pid = Shellwords.escape(helper_pid_path)
      escaped_controls = control_paths.map { |path| Shellwords.escape(path) }.join(' ')
      "set -e; if test -e #{escaped_helper_pid}; then " \
        "helper=$(cat #{escaped_helper_pid}); " \
        "case \"$helper\" in \"\"|*[!0-9]*) exit 1;; esac; " \
        "if kill -0 \"$helper\" 2>/dev/null; then " \
        "echo \"NFS modprobe helper still alive: $helper\" >&2; exit 1; fi; fi; " \
        "rm -f #{escaped_controls}"
    end

    def failed_nfs_container_cleanup_body(
      pid_paths: [
        '/root/nfs-failed-mount.pid',
        '/root/nfs-failed-mount-supervisor.pid'
      ],
      evidence_paths: [
        '/root/nfs-failed-mount.pid',
        '/root/nfs-failed-mount-supervisor.pid',
        '/root/nfs-failed-mount-status',
        '/root/nfs-failed-mount.log'
      ],
      mountpoint: '/mnt/nfs-failed'
    )
      escaped_pids = pid_paths.map { |path| Shellwords.escape(path) }.join(' ')
      escaped_evidence = evidence_paths.map { |path| Shellwords.escape(path) }.join(' ')
      escaped_mountpoint = Shellwords.escape(mountpoint)
      "set -e; for path in #{escaped_pids}; do " \
        "if test -e \"$path\"; then pid=$(cat \"$path\"); " \
        "case \"$pid\" in \"\"|*[!0-9]*) exit 1;; esac; " \
        "if kill -0 \"$pid\" 2>/dev/null; then " \
        "echo \"NFS mount process still alive: $pid ($path)\" >&2; exit 1; fi; fi; " \
        "done; rm -f #{escaped_evidence}; rmdir #{escaped_mountpoint}"
    end

    def emit_failed_nfs_mount_result(final: true)
      machine.execute(failed_nfs_mount_result_command, timeout: 15)
      @nfs_failed_mount_result_complete = true if final
    end

    def failed_nfs_auth_diagnostics(init_pid)
      control = nfs_namespace_control(init_pid)
      diagnostics = [
        [
          'mount process',
          "pid=$(osctl ct exec nfs1 cat /root/nfs-failed-mount.pid 2>/dev/null || true); " \
            "if test -n \"$pid\"; then echo NFS_FAILED_MOUNT_PID=$pid; " \
            "else echo NFS_FAILED_MOUNT_PID=missing; fi; " \
            "if test -n \"$pid\"; then proc=/proc/#{init_pid}/root/proc/$pid; " \
            "if test -d \"$proc\"; then printf 'cmdline='; " \
            "tr '\\0' ' ' < \"$proc/cmdline\"; echo; cat \"$proc/status\"; " \
            "printf 'wchan='; cat \"$proc/wchan\"; " \
            "printf 'syscall='; cat \"$proc/syscall\"; cat \"$proc/stack\"; " \
            "else echo NFS_FAILED_MOUNT_PROC=missing; fi; fi",
        ],
        [
          'transient servers',
          "#{control} " \
            "#{Shellwords.escape("mount --make-rslave /; mount -t sysfs sysfs /sys; " \
              "find /sys/fs/nfs -mindepth 1 -maxdepth 1 -type d " \
              "-name 'server-*' -printf 'NFS_TRANSIENT_SERVER=%f\\n' | sort")}",
        ],
        [
          'modprobe wrapper',
          "printf 'NFS_MODPROBE='; cat /proc/sys/kernel/modprobe; " \
            "stat -Lc 'NFS_WRAPPER mode=%a uid=%u gid=%g size=%s' " \
            "${blockedNfsAuthModprobe}; " \
            "if test -x ${blockedNfsAuthModprobe}; then " \
            "echo NFS_WRAPPER_READABLE=yes; else echo NFS_WRAPPER_READABLE=no; fi; " \
            "if test -e /run/nfs-failed-modprobe-invocations; then " \
            "cat /run/nfs-failed-modprobe-invocations; fi; " \
            "for marker in request release rejected; do " \
            "path=/run/nfs-failed-modprobe-$marker; " \
            "if test -e \"$path\"; then echo NFS_MODPROBE_MARKER_$marker=present; " \
            "cat \"$path\"; else echo NFS_MODPROBE_MARKER_$marker=absent; fi; done",
        ],
      ]

      diagnostics.each do |label, command|
        machine.execute(command, timeout: 15)
      rescue StandardError => e
        warn "NFS auth diagnostic #{label} failed: #{e.class}: #{e.message}"
      end

      emit_failed_nfs_mount_result(final: false)
    rescue StandardError => e
      warn "NFS auth mount-result diagnostic failed: #{e.class}: #{e.message}"
    end

    def with_blocked_nfs_auth_module
      original_modprobe = machine.succeeds('cat /proc/sys/kernel/modprobe')[1].strip
      @nfs_failed_mount_result_complete = false
      completed = false
      begin
        machine.all_succeed(
          "grep -q '^auth_rpcgss ' /proc/modules",
          "grep -q '^rpcsec_gss_krb5 ' /proc/modules",
          "test -x ${blockedNfsAuthModprobe}",
        )
        machine.succeeds(
          "rm -f /run/nfs-failed-modprobe-request " \
            "/run/nfs-failed-modprobe-release " \
            "/run/nfs-failed-modprobe-invocations " \
            "/run/nfs-failed-modprobe-rejected " \
            "/run/nfs-failed-modprobe-helper.pid",
        )
        machine.succeeds(
          "${kmod}/bin/rmmod rpcsec_gss_krb5 && " \
            "! grep -q '^rpcsec_gss_krb5 ' /proc/modules",
        )
        machine.succeeds(
          "sysctl -qw kernel.modprobe=${blockedNfsAuthModprobe}",
        )
        yield
        completed = true
      ensure
        cleanup_error = nil
        [
          ['release module request', -> { machine.succeeds('touch /run/nfs-failed-modprobe-release') }],
          [
            'stop unfinished mount',
            lambda do
              machine.succeeds(
                "osctl ct exec nfs1 sh -c " \
                  "#{Shellwords.escape(failed_nfs_mount_stop_body)}",
              )
            end,
          ],
          [
            'wait for mount supervisor',
            lambda do
              machine.wait_until_succeeds(
                "osctl ct exec nfs1 sh -c " \
                  "#{Shellwords.escape(failed_nfs_mount_supervisor_done_body)}",
                timeout: 15,
              )
            end,
          ],
          [
            'emit failed mount result',
            lambda do
              emit_failed_nfs_mount_result unless @nfs_failed_mount_result_complete
            end,
          ],
          [
            'unmount failed target',
            lambda do
              machine.succeeds(
                "osctl ct exec nfs1 sh -c " \
                  "'if mountpoint -q /mnt/nfs-failed; then umount /mnt/nfs-failed; fi'",
              )
            end,
          ],
          [
            'restore kernel.modprobe',
            lambda do
              machine.succeeds(
                "sysctl -qw kernel.modprobe=#{Shellwords.escape(original_modprobe)}",
              )
            end,
          ],
          [
            'restore KRB5 mechanism module',
            lambda do
              machine.succeeds(
                "${kmod}/bin/modprobe rpcsec_gss_krb5 && " \
                  "grep -q '^rpcsec_gss_krb5 ' /proc/modules",
              )
            end,
          ],
          [
            'remove host failure controls',
            -> { machine.succeeds(failed_nfs_host_cleanup_body) },
          ],
          [
            'remove container failure controls',
            lambda do
              machine.succeeds(
                "osctl ct exec nfs1 sh -ec " \
                  "#{Shellwords.escape(failed_nfs_container_cleanup_body)}",
              )
            end,
          ],
        ].each do |operation, cleanup|
          begin
            cleanup.call
          rescue StandardError => e
            cleanup_error ||= e
            warn "NFS failed-mount #{operation} cleanup failed: #{e.class}: #{e.message}"
          end
        end
        @nfs_failed_mount_result_complete = nil
        raise cleanup_error if completed && cleanup_error
      end
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

        it "drains an admitted shutdown writer before final unmount" do
            init_pid = Integer(machine.succeeds("osctl ct show -H -o init_pid nfs1")[1].strip)
            mount_id = machine.succeeds(
              "osctl ct exec nfs1 awk '$5 == \"/mnt/nfs\" { print $3 }' /proc/self/mountinfo",
            )[1].strip
            expect(mount_id).to match(/\A\d+:\d+\z/)
            payload = "teardown-race-#{version}"
            machine.succeeds(
              "osctl ct exec nfs2 sh -c 'printf %s #{payload} > /mnt/nfs/#{payload}'",
            )
            control = nfs_namespace_control(init_pid)

            with_restored_nfs_client(version) do
              output = machine.succeeds(
                "#{control} 'mount --make-rslave /; mount -t sysfs sysfs /sys; " \
                  "exec /run/nfs-shutdown-unmount " \
                  "/sys/fs/nfs/#{mount_id}/shutdown #{init_pid} /mnt/nfs'",
                timeout: 60,
              )[1]
              expect(output).to match(/\Ashutdown_writes=[1-9]\d* unmounted=1\n\z/)
              machine.fails("osctl ct exec nfs1 mountpoint -q /mnt/nfs")
              expect(machine.succeeds("osctl ct exec nfs2 cat /mnt/nfs/#{payload}")[1])
                .to eq(payload)
            end
          end

        if version == '3'
          it "releases a server after post-publication RPC auth setup fails" do
              init_pid = Integer(machine.succeeds("osctl ct show -H -o init_pid nfs1")[1].strip)
              before_servers = transient_nfs_server_ids(init_pid)
              dmesg_before = machine.succeeds('dmesg')[1]
              control = nfs_namespace_control(init_pid)

              with_blocked_nfs_auth_module do
                mount_command =
                  "/sbin/mount.nfs 10.0.0.10:/srv/nfs-cancellation-auth-null " \
                  "/mnt/nfs-failed -o " \
                  "vers=3,proto=tcp,${nfsRetryOptions},sec=krb5,nolock,retry=0"
                supervisor = failed_nfs_mount_supervisor_command(mount_command: mount_command)
                launch =
                  "mkdir -p /mnt/nfs-failed; " \
                  "rm -f /root/nfs-failed-mount.pid " \
                  "/root/nfs-failed-mount-supervisor.pid /root/nfs-failed-mount-status " \
                  "/root/nfs-failed-mount.log; " \
                  "nohup sh -c #{Shellwords.escape(supervisor)} " \
                  ">/dev/null 2>&1 </dev/null & " \
                  "echo $! > /root/nfs-failed-mount-supervisor.pid"
                machine.succeeds(
                  "osctl ct exec nfs1 sh -c #{Shellwords.escape(launch)}",
                )
              begin
                trigger = machine.succeeds(
                  "i=0; while test \"$i\" -lt 300; do " \
                    "if test -s /run/nfs-failed-modprobe-request; " \
                    "then echo marker; exit 0; " \
                    "elif osctl ct exec nfs1 test -s /root/nfs-failed-mount-status; " \
                    "then echo status; exit 0; fi; " \
                    "${pkgs.coreutils}/bin/sleep 0.1; i=$((i + 1)); done; exit 1",
                  timeout: 35,
                )[1].strip
                rescue StandardError
                  failed_nfs_auth_diagnostics(init_pid)
                  raise
                end
                if trigger == 'status'
                  emit_failed_nfs_mount_result
                  status = machine.succeeds(
                    'osctl ct exec nfs1 cat /root/nfs-failed-mount-status',
                  )[1].strip
                  raise "NFS auth trigger exited before module request with status #{status}"
                end
                expect(trigger).to eq('marker')
              request = machine.succeeds(
                "test ! -e /run/nfs-failed-modprobe-rejected; " \
                  "test \"$(wc -l < /run/nfs-failed-modprobe-invocations)\" = 1; " \
                  "cat /run/nfs-failed-modprobe-request",
              )[1].strip
                expect(request).to eq('rpc-auth-gss-390003')

                new_servers = transient_nfs_server_ids(init_pid) - before_servers
                expect(new_servers.length).to eq(1)
                server_id = new_servers.fetch(0)
                callback_body =
                  "mount --make-rslave /; mount -t sysfs sysfs /sys; " \
                  "server=/sys/fs/nfs/#{server_id}; test \"$(cat \"$server/shutdown\")\" = 0; " \
                  "result=$(/run/nfs-shutdown-unmount --expect-eagain \"$server/shutdown\"); " \
                  "test \"$result\" = partial_callback=eagain; " \
                  "test \"$(cat \"$server/shutdown\")\" = 0; " \
                  "test \"$(cat /sys/fs/nfs/net/nfs_client/shutdown)\" = 0; " \
                  "test \"$(cat /sys/fs/nfs/net/nfs_client/shutdown_tree)\" = 0; " \
                  "printf '%s\\n' \"$result\""
                callback_output = machine.succeeds(
                  "#{control} #{Shellwords.escape(callback_body)}",
                  timeout: 15,
                )[1]
                expect(callback_output).to eq("partial_callback=eagain\n")
                puts "POST_PUBLICATION_NFSV3_FAILURE server=#{server_id} " \
                  "request=#{request.strip} partial_callback=eagain"

                machine.succeeds('touch /run/nfs-failed-modprobe-release')
                machine.wait_until_succeeds(
                  'osctl ct exec nfs1 test -s /root/nfs-failed-mount-status',
                  timeout: 30,
                )
                status = Integer(
                  machine.succeeds('osctl ct exec nfs1 cat /root/nfs-failed-mount-status')[1].strip,
                )
                expect(status).to be > 0
                emit_failed_nfs_mount_result
                machine.wait_until_succeeds(
                  "#{control} " \
                    "#{Shellwords.escape("mount --make-rslave /; mount -t sysfs sysfs /sys; " \
                      "test ! -e /sys/fs/nfs/#{server_id}")}",
                  timeout: 30,
                )
                expect(transient_nfs_server_ids(init_pid) - before_servers).to be_empty
                machine.fails('osctl ct exec nfs1 mountpoint -q /mnt/nfs-failed')

                payload = 'post-publication-failure-survived'
                machine.succeeds(
                  "osctl ct exec nfs2 sh -c 'printf %s #{payload} > /mnt/nfs/#{payload}'",
                )
                expect(machine.succeeds("osctl ct exec nfs2 cat /mnt/nfs/#{payload}")[1])
                  .to eq(payload)

                dmesg_after = machine.succeeds('dmesg')[1]
                expect(dmesg_after).to start_with(dmesg_before)
                new_dmesg = dmesg_after.delete_prefix(dmesg_before)
                expect(new_dmesg).not_to match(
                  /BUG:|Oops:|KASAN|refcount_t:|list_del corruption|hung task/i,
                )
              end
            end

          it "shuts down a legacy server before the first NLM lock" do
            # The v3 mount constructor binds its NLM RPC client eagerly.
            # Exercise the old per-server ABI with that idle client before
            # any remote-lock example, and prove the other client survives.
            init_pid = machine.succeeds("osctl ct show -H -o init_pid nfs1")[1].strip
            mount_id = machine.succeeds(
              "osctl ct exec nfs1 awk '$5 == \"/mnt/nfs\" { print $3 }' /proc/self/mountinfo",
            )[1].strip
            expect(mount_id).to match(/\A\d+:\d+\z/)
            control = nfs_namespace_control(init_pid, trace: true)
            with_restored_nfs_client(version) do
              machine.succeeds('echo legacy-data > /srv/nfs-cancellation/legacy-shutdown')
              machine.succeeds(
                "#{control} 'mount --make-rslave /; mount -t sysfs sysfs /sys; " \
                  "server=/sys/fs/nfs/#{mount_id}; set -- \"$server/shutdown\"; " \
                  "test -f \"$1\"; " \
                  "test -L \"$server/lockd_client\"; " \
                  "test \"$(cat \"$1\")\" = 0; " \
                  "echo 1 > \"$1\"; test \"$(cat \"$1\")\" = 1'",
              )
              machine.fails("osctl ct exec nfs1 cat /mnt/nfs/legacy-shutdown")
              machine.succeeds(
                "osctl ct exec nfs2 sh -c 'echo legacy-survived > /mnt/nfs/other-client'",
              )
              expect(machine.succeeds('cat /srv/nfs-cancellation/other-client')[1].strip)
                .to eq('legacy-survived')
            end
          end
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
                "-o vers=#{version},proto=tcp,port=2049,${nfsRetryOptions},nolock " \
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
              nfs_server = "${utilLinux}/bin/nsenter " \
                "-t $(cat /run/osctl/exportfs/servers/server1/pid) -m -n -p"
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
          restore = [
            ['restore network', -> { isolate_client('D') }],
            [
              'release child network namespace',
              lambda do
                machine.succeeds(
                  "if mountpoint -q #{held_net}; then umount #{held_net}; fi; rm -f #{held_net}",
                )
              end,
            ],
          ]
          with_restored_nfs_client(version, before_restore: restore) do
            machine.all_succeed(
              "osctl ct exec nfs1 mkdir -p /mnt/nfs-child",
              "osctl ct exec nfs1 ip netns add nfstest",
              "osctl ct exec nfs1 ip link set eth0 netns nfstest",
              "osctl ct exec nfs1 ip -n nfstest link set lo up",
              "osctl ct exec nfs1 ip -n nfstest link set eth0 up",
              "osctl ct exec nfs1 ip -n nfstest addr replace 192.168.1.21/24 dev eth0",
              "osctl ct exec nfs1 ip -n nfstest route replace default via 192.168.1.1 dev eth0",
              "osctl ct exec nfs1 nsenter --net=/run/netns/nfstest mount -t nfs " \
                "-o vers=#{version},proto=tcp,${nfsRetryOptions},nolock " \
                "10.0.0.10:/srv/nfs-cancellation /mnt/nfs-child",
              "osctl ct exec nfs1 sh -c 'echo child-live > /mnt/nfs-child/child-live; sync'",
              "touch #{held_net}",
              "mount --bind /proc/#{init_pid}/root/run/netns/nfstest #{held_net}",
            )
            # The host bind mount retains only a namespace reference, not
            # a process which the cancellation scanner could discover. Keep
            # the root mount alive so its retained owner control can cancel
            # blocked work in the otherwise undiscoverable child namespace.
            expect(machine.succeeds("osctl ct exec nfs1 ip netns pids nfstest")[1].strip).to be_empty
            isolate_client('I')
            start_writer(version, '/mnt/nfs-child')
            sleep(5)
            machine.fails("osctl ct exec nfs1 test -e /root/nfs-done")
            stop_nfs_client
            expect(machine.succeeds("osctl ct show -H -o state nfs1")[1].strip).to eq('stopped')
            owner = nfs_namespace_path_control(held_net)
            state = machine.succeeds(
              "#{owner} 'mount --make-rslave /; mount -t sysfs sysfs /sys; " \
                "cat /sys/fs/nfs/net/nfs_client/shutdown'",
            )[1].strip
            expect(state).to eq('1')
            # The child network namespace shares the root owner's barrier
            # without ever being discovered by a process scan.
            machine.succeeds(
              "#{owner} 'mount --make-rslave /; mount -t sysfs sysfs /sys; " \
                "test \"$(cat /sys/fs/nfs/net/nfs_client/shutdown_tree)\" = 1'",
            )
            machine.succeeds("osctl ct exec nfs2 sh -c 'echo child-survived > /mnt/nfs/other-client'")
          end
        end

        it "rejects new mounts and descendants after host terminal cancellation" do
          init_pid = Integer(machine.succeeds("osctl ct show -H -o init_pid nfs1")[1].strip)
          # Tenant root must not be able to set a host-owned terminal policy.
          machine.fails(
            "osctl ct exec nfs1 sh -c 'echo 1 > /sys/fs/nfs/net/nfs_client/shutdown_tree'",
          )
          control = nfs_namespace_control(init_pid)
          machine.succeeds(
            "#{control} 'mount --make-rslave /; mount -t sysfs sysfs /sys; " \
              "test \"$(cat /sys/fs/nfs/net/nfs_client/shutdown_tree)\" = 0; " \
              "echo 1 > /sys/fs/nfs/net/nfs_client/shutdown_tree'",
          )
          # The server is online. Neither a fresh mount nor a repeat write
          # may reset the admission barrier in the existing namespace.
          mount_command = "osctl ct exec nfs1 mount -t nfs " \
            "-o vers=#{version},proto=tcp,${nfsRetryOptions},nolock " \
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
                "#{nfs_namespace_path_control(netns)} " \
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
          control = nfs_namespace_control(init_pid)

          modes = machine.succeeds(
            "osctl ct exec nfs1 stat -c '%a' " \
              "/sys/fs/nfs/net/nfs_client/shutdown " \
              "/sys/fs/nfs/net/nfs_client/shutdown_tree",
          )[1].split
          expect(modes).to eq(%w[600 600])

          # Tenant access is a permission failure, never a missing control.
          # Join streams inside the container so transport scheduling cannot
          # move cat's diagnostic after the status marker.
          tenant = machine.succeeds(
            "osctl ct exec nfs1 sh -c " \
              "'exec 2>&1; cat /sys/fs/nfs/net/nfs_client/shutdown >/dev/null; echo rc=$?'",
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
          control = nfs_namespace_control(init_pid)
          rules = [
            "FORWARD -s 192.168.1.21 -d 10.0.0.10 -p tcp --dport 2049 -j DROP",
            "FORWARD -s 10.0.0.10 -d 192.168.1.21 -p tcp --sport 2049 -j DROP",
          ]
          rules.each { |rule| machine.succeeds("iptables -I #{rule}") }
          begin
            machine.succeeds(
              "osctl ct exec nfs1 sh -c 'nohup mount -t nfs " \
                "-o vers=#{version},proto=tcp,port=2049,${nfsRetryOptions},nolock " \
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
            shutdown_writer = <<~'RUBY'
              path = '/sys/fs/nfs/net/nfs_client/shutdown_tree'
              clock = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
              started = clock.call
              deadline = started + 30
              busy_count = 0
              outcome = 'failure'
              begin
                loop do
                  raise Errno::EBUSY, 'NFS shutdown retry deadline exhausted' if clock.call >= deadline

                  control = nil
                  busy = false
                  begin
                    control = File.open(path, 'w')
                    written = control.syswrite("1\n")
                  rescue Errno::EBUSY
                    busy = true
                    busy_count += 1
                  ensure
                    control&.close
                  end
                  if busy
                    remaining = deadline - clock.call
                    raise Errno::EBUSY, 'NFS shutdown retry deadline exhausted' if remaining <= 0

                    sleep([0.05, remaining].min)
                    next
                  end

                  raise IOError, "partial NFS shutdown write: #{written.inspect}" unless written == 2
                  raise IOError, 'NFS shutdown barrier readback is not 1' unless File.read(path) == "1\n"

                  outcome = 'success'
                  break
                end
              ensure
                warn "NFS shutdown busy_count=#{busy_count} elapsed=#{(clock.call - started).round(3)} outcome=#{outcome}"
              end
            RUBY
            shutdown_command = "${pkgs.ruby}/bin/ruby -e #{Shellwords.escape(shutdown_writer)}"
            machine.succeeds(
              "#{control} #{Shellwords.escape("mount --make-rslave /; mount -t sysfs sysfs /sys; #{shutdown_command}")}",
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
                "-o vers=#{version},proto=tcp,${nfsRetryOptions},nolock " \
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
          control = nfs_namespace_control(init_pid)
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
          control = nfs_namespace_control(init_pid)
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
          control = nfs_namespace_control(init_pid)
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
            control = nfs_namespace_control(init_pid)
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

        after(:context) do
          %w[nfs1 nfs2].each do |ct|
            # Preserve the original failure if an example could not restart
            # its container; cleanup must not replace it with an exec error.
            next unless machine.succeeds("osctl ct show -H -o state #{ct}")[1].strip == 'running'

            machine.succeeds(
              "osctl ct exec #{ct} sh -c " \
                "'if mountpoint -q /mnt/nfs; then umount /mnt/nfs; fi'",
            )
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
