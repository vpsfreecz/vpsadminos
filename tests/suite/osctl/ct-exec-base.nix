{ name, config }:
import ../../make-test.nix (
  { pkgs }:
  {
    name = "osctl-ct-exec-${name}";

    description = ''
      Test osctl ct exec
    '';

    tags = [ "ci" ];

    machine = import ../../machines/vpsadminos/with-tank.nix {
      inherit pkgs config;
    };

    testScript = ''
      machine.start
      machine.wait_for_osctl_pool("tank")
      machine.wait_until_online

      machine.all_succeed(
        "osctl ct new --distribution alpine startedct",
        "osctl ct unset start-menu startedct",
        "osctl ct new --distribution alpine stoppedct",
        "osctl ct netif new routed stoppedct eth0",
        "osctl ct netif ip add stoppedct eth0 1.2.3.4/32",
        "osctl ct start startedct",
      )

      machine.wait_until_succeeds('osctl ct exec startedct rc-service networking status')
      2.times do |generation|
        if generation > 0
          machine.succeeds('osctl ct restart startedct')
          machine.wait_until_succeeds('osctl ct exec startedct rc-service networking status')
        end
        current_init = machine.osctl_json('ct show startedct').fetch('init_pid')
        machine.succeeds("cat /proc/#{current_init}/cgroup; grep ' - cgroup' /proc/#{current_init}/mountinfo")
        _, helper_cgroups = machine.succeeds('osctl ct exec startedct cat /proc/self/cgroup')
        helper_cgroups.lines.each do |line|
          path = line.strip.split(':', 3).fetch(2)
          expect(path.split('/')).not_to include('..'), "helper escaped its cgroup namespace after restart=#{generation}: #{line}"
        end
      end
      init = machine.osctl_json('ct show startedct').fetch('init_pid')
      protected_paths = %w[/ /proc /proc/sys /proc/sys/net /proc/sys/kernel/random/boot_id /run]
      protected_mounts = lambda do
        machine.succeeds("cat /proc/#{init}/mountinfo")[1].lines.select do |line|
          protected_paths.include?(line.split[4])
        end
      end
      initial_mounts = protected_mounts.call
      expect(initial_mounts.map { |line| line.split[4] }).to include('/proc/sys')
      machine.succeeds("osctl ct exec startedct sh -c 'echo helper-data > /root/helper-data'")
      {
        'exec' => 'osctl ct exec startedct true',
        'attach' => "printf 'exit 0\\n' | osctl ct attach startedct",
        'su' => "printf 'exit 0\\n' | osctl ct su startedct",
        'runscript' => "printf '#!/bin/sh\\nexit 0\\n' | osctl ct runscript startedct -",
        'cat' => 'osctl ct cat startedct /root/helper-data',
      }.each do |operation, command|
        if operation == 'cat'
          machine.succeeds(<<~SH)
            set -eu
            t=/sys/kernel/tracing
            mountpoint -q "$t" || mount -t tracefs tracefs "$t"
            echo 0 > "$t/tracing_on"
            echo nop > "$t/current_tracer"
            echo 2048 > "$t/buffer_size_kb"
            grep -E '^(d_invalidate|__detach_mounts|proc_misc_d_revalidate|vpsa_kernfs_filter_dentry_visibility_stale)( |$)' "$t/available_filter_functions"
            printf 'd_invalidate\n__detach_mounts\n' > "$t/set_ftrace_filter"
            echo function > "$t/current_tracer"
            echo 1 > "$t/options/func_stack_trace"
            echo 'r:helper_visibility_stale vpsa_kernfs_filter_dentry_visibility_stale stale=$retval:u8' >> "$t/kprobe_events"
            echo 'stale == 1' > "$t/events/kprobes/helper_visibility_stale/filter"
            echo 1 > "$t/events/kprobes/helper_visibility_stale/enable"
            echo 'r:helper_proc_revalidate proc_misc_d_revalidate result=$retval:s32' >> "$t/kprobe_events"
            echo 'result == 0' > "$t/events/kprobes/helper_proc_revalidate/filter"
            echo 1 > "$t/events/kprobes/helper_proc_revalidate/enable"
            echo > "$t/trace"
            echo 1 > "$t/tracing_on"
          SH
        end

        begin
          machine.succeeds(command)
        ensure
          if operation == 'cat'
            machine.succeeds(<<~SH)
              set -eu
              t=/sys/kernel/tracing
              echo 0 > "$t/tracing_on"
              cat "$t/trace"
              echo 0 > "$t/events/kprobes/helper_visibility_stale/enable"
              echo 0 > "$t/events/kprobes/helper_proc_revalidate/enable"
              echo '-:helper_visibility_stale' >> "$t/kprobe_events"
              echo '-:helper_proc_revalidate' >> "$t/kprobe_events"
              echo 0 > "$t/options/func_stack_trace"
              echo nop > "$t/current_tracer"
              echo > "$t/set_ftrace_filter"
            SH
          end
        end
        expect(protected_mounts.call).to eq(initial_mounts), "ct #{operation} changed protected mounts"
      end

      common_tests = Proc.new do |msg, ctid, opts|
        # capture stdout
        _, output = machine.succeeds("osctl ct exec #{opts} #{ctid} echo hi")

        if output.strip != "hi"
          fail "#{msg}: unexpected exec output: #{output.inspect}"
        end

        # capture stderr
        _, output = machine.succeeds("osctl ct exec #{opts} #{ctid} sh -c '>&2 echo hi'")

        if output.strip != "hi"
          fail "#{msg}: unexpected exec output: #{output.inspect}"
        end

        # exit status
        st, output = machine.execute("osctl ct exec #{opts} #{ctid} sh -c 'exit 33'")

        if st != 33
          fail "#{msg}: unexpected exec status: #{st.inspect}"
        elsif output.strip != "error: executed command failed"
          fail "#{msg}: unexpected exec output: #{output.inspect}"
        end

        # invalid command
        st, output = machine.execute("osctl ct exec #{opts} #{ctid} totally-madeup-command")

        # exitstatus and output differs based on whether the container is running
        # or is brought up with lxc-execute, so we just check that it returns
        # non-zero status
        if st == 0
          fail "#{msg}: unexpected exec status: #{st.inspect}"
        end
      end


      # Exec on a running container
      _, output = machine.succeeds("osctl ct show -H -o state startedct")

      if output.strip != "running"
        fail "startedct is in an unexpected state: #{output.inspect}"
      end

      common_tests.call(
        'exec on a running container',
        'startedct',
        "",
      )


      # Exec on a stopped container
      _, output = machine.succeeds("osctl ct show -H -o state stoppedct")

      if output.strip != "stopped"
        fail "stoppedct is in an unexpected state: #{output.inspect}"
      end

      common_tests.call(
        'exec on a stopped container',
        'stoppedct',
        '-r',
      )


      # Exec on a running container with -r
      _, output = machine.succeeds("osctl ct show -H -o state startedct")

      if output.strip != "running"
        fail "startedct is in an unexpected state: #{output.inspect}"
      end

      common_tests.call(
        'exec on a running container with -r',
        'startedct',
        '-r',
      )


      # Exec on a stopped container with networking
      _, output = machine.succeeds("osctl ct show -H -o state stoppedct")

      if output.strip != "stopped"
        fail "stoppedct is in an unexpected state: #{output.inspect}"
      end

      common_tests.call(
        'exec on a stopped container with networking',
        'stoppedct',
        '-rn',
      )

      machine.succeeds("osctl ct exec -rn stoppedct ping -c 1 1.2.3.4")
      machine.succeeds("osctl ct exec -rn stoppedct ping -c 1 255.255.255.254")

      _, output = machine.succeeds("osctl ct exec -rn stoppedct ip route show")

      if output.strip != "default via 255.255.255.254 dev eth0 \n255.255.255.254 dev eth0 scope link"
        fail "unexpected default route: #{output.inspect}"
      end


      # Exec on a running container with networking
      _, output = machine.succeeds("osctl ct show -H -o state startedct")

      if output.strip != "running"
        fail "startedct is in an unexpected state: #{output.inspect}"
      end

      common_tests.call(
        'exec on a running container with -rn',
        'startedct',
        '-rn',
      )
    '';
  }
)
