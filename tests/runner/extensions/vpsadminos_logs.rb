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
      run dmesg -T
      run ps -eo pid,ppid,stat,comm,args
      run_sh 'sv status /service/*'

      if command -v osctl >/dev/null 2>&1; then
        run_sh 'timeout 10 osctl pool ls'
        run_sh 'timeout 10 osctl ct ls'
        run_sh 'timeout 10 osctl ct ls -H -o pool,id,state,init-pid,log-file 2>/dev/null || true'
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
