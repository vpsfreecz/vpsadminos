require 'fileutils'

module VpsadminosFailureLogs
  module_function

  def collect(machine, path)
    FileUtils.mkdir_p(File.dirname(path))

    status, output = machine.execute(diagnostics_script, timeout: 300)

    File.open(path, 'w') do |f|
      f.puts("machine: #{machine.name}")
      f.puts("status: #{status}")
      f.puts
      f.write(output)
    end
  rescue StandardError => e
    File.open(path, 'w') do |f|
      f.puts("machine: #{machine.name}")
      f.puts("diagnostic collection failed: #{e.class}: #{e.message}")
      f.puts(e.backtrace.join("\n")) if e.backtrace
    end
  end

  def diagnostics_script
    <<~'SH'
      set +e

      section() {
        printf '\n===== %s =====\n' "$*"
      }

      run() {
        section "$*"
        "$@" 2>&1
      }

      run_sh() {
        section "$1"
        sh -c "$1" 2>&1
      }

      show_file() {
        file="$1"
        [ -e "$file" ] || return 0
        section "$file"
        cat "$file" 2>&1
      }

      show_glob() {
        pattern="$1"

        for file in $pattern; do
          [ -e "$file" ] || continue
          show_file "$file"
        done
      }

      run date -Ins
      run uname -a
      run uptime
      run free -m
      run df -h
      # A routed guest can remain running while its host route is unusable.
      # Snapshot route selection and link state before teardown removes the veth.
      run_sh 'timeout 10 ip -o link show'
      run_sh 'timeout 10 ip -4 addr show'
      run_sh 'timeout 10 ip -4 rule show'
      run_sh 'timeout 10 ip -4 route show table all'
      run dmesg -T
      run ps -eo pid,ppid,stat,comm,args

      # A ps snapshot shows blocked tasks but not what they await. Capture
      # a bounded set of kernel stacks before teardown changes their state.
      section 'D-state and ZFS sync-task kernel stacks'
      ps -eo pid=,stat=,comm= |
        awk '$2 ~ /^D/ || $3 == "dp_sync_taskq" { print $1, $2, $3 }' |
        head -n 16 |
        while read -r pid state comm; do
          section "/proc/$pid/stack ($state $comm)"
          timeout 2 cat "/proc/$pid/stack" 2>&1
        done

      run_sh 'sv status /service/*'

      if command -v osctl >/dev/null 2>&1; then
        run_sh 'timeout 10 osctl pool ls'
        run_sh 'timeout 10 osctl ct ls'
        run_sh 'timeout 10 osctl ct ls -H -o pool,id,state,init-pid,log-file 2>/dev/null || true'

        # DNS readiness failures need the guest's state, not only host routes.
        # Avoid the attach helper under investigation; never change networking.
        section 'Running guest resolver/address/route state'
        timeout 10 osctl ct ls -H -o pool,id,state,init-pid |
          awk '$3 == "running" && $4 ~ /^[1-9][0-9]*$/ { print $1, $2, $4 }' |
          head -n 16 |
          while read -r pool id pid; do
            section "$pool:$id network (init $pid)"
            timeout 5 nsenter -t "$pid" -n -- sh -c \
              'ip -o link show; ip -4 addr show; ip -6 addr show; ip -4 route show table all; ip -6 route show table all' 2>&1
            section "$pool:$id /etc/resolv.conf (init $pid)"
            # Resolve absolute symlinks inside the guest root as well.
            timeout 2 nsenter -t "$pid" -m -r -- /bin/sh -c \
              'PATH=/run/current-system/sw/bin:/usr/bin:/bin; cat /etc/resolv.conf' 2>&1
          done
      fi

      run_sh 'ls -la /run/osctl /run/osctl/pools /service/osctld /var/log /tank/log /tank/log/ct 2>/dev/null'

      show_file /var/log/osctld
      show_file /var/log/messages
      show_glob '/tank/log/ct/*'
      show_glob '/tank/log/ct/*.destroyed'
      show_glob '/tmp/osctld-restart-jobs/*'
      show_glob '/tmp/osctld-restart-blocks/*/*'
    SH
  end
end

TestRunner::Hook.subscribe(:after_test_script_run) do |script_result:, machines:, state_dir:, **|
  next unless script_result.unexpected_result?

  machines.each_value do |machine|
    next unless machine.running? && machine.can_execute?

    path = File.join(state_dir, "#{machine.name}-failure-diagnostics.log")
    VpsadminosFailureLogs.collect(machine, path)
  end
end
