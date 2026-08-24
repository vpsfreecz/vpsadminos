import ../../make-test.nix (
  { pkgs }:
  let
    consoleClient = pkgs.writeText "ct-console-client.rb" ''
      require 'pty'
      require 'timeout'

      ctid = ENV.fetch('CTID')
      message = ENV.fetch('MESSAGE')
      output = String.new

      def read_until(io, output, needle)
        Timeout.timeout(20) do
          until output.include?(needle)
            output << io.readpartial(4096)
          end
        end
      end

      PTY.spawn('osctl', 'ct', 'console', ctid) do |r, w, pid|
        begin
          read_until(r, output, 'Press Ctrl+a q')
          w.write("#{message}\n")
          read_until(r, output, "CTCONSOLE_ECHO:#{message}")
          w.write("\x01q")
          _, status = Timeout.timeout(10) { Process.wait2(pid) }

          unless status.success?
            warn output
            abort "console exited with #{status.exitstatus.inspect}"
          end

          puts output
        rescue Exception
          warn output
          Process.kill('TERM', pid) rescue nil
          Process.wait(pid) rescue nil
          raise
        end
      end
    '';

    persistentConsoleClient = pkgs.writeText "ct-console-persistent-client.rb" ''
      require 'pty'
      require 'timeout'

      ctid = ENV.fetch('CTID')
      ready = ENV.fetch('READY')
      continue = ENV.fetch('CONTINUE')
      output = String.new

      def read_until(io, output, needle, timeout: 20)
        Timeout.timeout(timeout) do
          until output.include?(needle)
            output << io.readpartial(4096)
          end
        end
      end

      def wait_for_file(path, timeout: 120)
        Timeout.timeout(timeout) do
          sleep(0.1) until File.exist?(path)
        end
      end

      PTY.spawn('osctl', 'ct', 'console', ctid) do |r, w, pid|
        begin
          read_until(r, output, 'Press Ctrl+a q')

          w.write("before-cycle\n")
          read_until(r, output, 'CTCONSOLE_ECHO:before-cycle')
          File.write(ready, output)

          wait_for_file(continue)

          w.write("after-cycle\n")
          read_until(
            r,
            output,
            'CTCONSOLE_ECHO:after-cycle',
            timeout: 60
          )
          w.write("\x01q")
          _, status = Timeout.timeout(10) { Process.wait2(pid) }

          unless status.success?
            warn output
            abort "console exited with #{status.exitstatus.inspect}"
          end

          puts output
        rescue Exception
          warn output
          Process.kill('TERM', pid) rescue nil
          Process.wait(pid) rescue nil
          raise
        end
      end
    '';

    resizeConsoleClient = pkgs.writeText "ct-console-resize-client.rb" ''
      require 'io/console'
      require 'pty'
      require 'timeout'

      ctid = ENV.fetch('CTID')
      rows = Integer(ENV.fetch('ROWS'))
      cols = Integer(ENV.fetch('COLS'))
      expected = "CTCONSOLE_SIZE:#{rows} #{cols}"
      output = String.new

      def read_until(io, output, needle, timeout: 20)
        Timeout.timeout(timeout) do
          until output.include?(needle)
            output << io.readpartial(4096)
          end
        end
      end

      def read_available_for(io, output, seconds)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds

        loop do
          remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          break if remaining <= 0

          rs, = IO.select([io], nil, nil, remaining)
          break if rs.nil?

          output << io.readpartial(4096)
        end
      end

      def wait_for_size(read_io, write_io, output, expected)
        Timeout.timeout(20) do
          until output.include?(expected)
            write_io.write("CTCONSOLE_SIZE\n")
            read_available_for(read_io, output, 0.5)
          end
        end
      end

      PTY.spawn('osctl', 'ct', 'console', ctid) do |r, w, pid|
        begin
          read_until(r, output, 'Press Ctrl+a q')

          w.write("resize-ready\n")
          read_until(r, output, 'CTCONSOLE_ECHO:resize-ready')

          r.winsize = [rows, cols]
          sleep(0.2)
          wait_for_size(r, w, output, expected)

          w.write("\x01q")
          _, status = Timeout.timeout(10) { Process.wait2(pid) }

          unless status.success?
            warn output
            abort "console exited with #{status.exitstatus.inspect}"
          end

          puts output
        rescue Exception
          warn output
          Process.kill('TERM', pid) rescue nil
          Process.wait(pid) rescue nil
          raise
        end
      end
    '';

    containerInit = pkgs.writeScript "ct-console-init.sh" ''
      #!/bin/sh
      trap 'exit 0' TERM INT HUP PWR
      echo CTCONSOLE_READY
      while IFS= read -r line; do
        if [ "$line" = CTCONSOLE_SIZE ]; then
          echo "CTCONSOLE_SIZE:$(stty size)"
        else
          echo "CTCONSOLE_ECHO:$line"
        fi
      done
    '';
  in
  {
    name = "osctl-ct-console";

    description = ''
      Test osctl ct console
    '';

    tags = [ "ci" ];

    machine = import ../../machines/vpsadminos/tank.nix pkgs;

    testScript = ''
      require 'shellwords'

      CONSOLE_CLIENT = "/tmp/ct-console-client.rb"
      PERSISTENT_CONSOLE_CLIENT = "/tmp/ct-console-persistent-client.rb"
      RESIZE_CONSOLE_CLIENT = "/tmp/ct-console-resize-client.rb"

      def self.output_of(command)
        machine.succeeds(command)[1].strip
      end

      def self.ct_state(ctid)
        output_of("osctl ct show -H -o runtime_state #{ctid}")
      end

      def self.wait_ct_state(ctid, state, timeout: 60)
        machine.wait_until_succeeds(
          "test \"$(osctl ct show -H -o runtime_state #{ctid})\" = #{state}",
          timeout:
        )
      end

      def self.console_roundtrip(ctid, message)
        env = [
          "CTID=#{Shellwords.escape(ctid)}",
          "MESSAGE=#{Shellwords.escape(message)}"
        ].join(' ')

        _, output = machine.succeeds(
          "#{env} ruby #{Shellwords.escape(CONSOLE_CLIENT)}"
        )

        output
      end

      def self.console_resize(ctid, rows, cols)
        env = [
          "CTID=#{Shellwords.escape(ctid)}",
          "ROWS=#{rows}",
          "COLS=#{cols}"
        ].join(' ')

        _, output = machine.succeeds(
          "#{env} ruby #{Shellwords.escape(RESIZE_CONSOLE_CLIENT)}"
        )

        output
      end

      def self.restart_osctld
        machine.succeeds("sv -w 180 restart osctld")
        machine.wait_for_osctl_pool("tank")
      end

      def self.background_job(name, script)
        dir = '/tmp/ct-console-jobs'
        log_path = "#{dir}/#{name}.log"
        status_path = "#{dir}/#{name}.status"
        pid_path = "#{dir}/#{name}.pid"
        runner = <<~SH
          (
            set -e
            #{script}
          )
          rc=$?
          printf '%s\\n' "$rc" > #{Shellwords.escape(status_path)}
          exit "$rc"
        SH

        machine.succeeds(<<~CMD)
          install -d -m 755 #{Shellwords.escape(dir)}
          rm -f #{Shellwords.escape(log_path)} #{Shellwords.escape(status_path)} #{Shellwords.escape(pid_path)}
          nohup sh -c #{Shellwords.escape(runner)} > #{Shellwords.escape(log_path)} 2>&1 &
          echo $! > #{Shellwords.escape(pid_path)}
        CMD

        {
          name:,
          log_path:,
          status_path:,
          pid_path:
        }
      end

      def self.wait_background_job(job, timeout: 120)
        machine.wait_until_succeeds(
          "test -f #{Shellwords.escape(job[:status_path])}",
          timeout:
        )

        status = output_of("cat #{Shellwords.escape(job[:status_path])}")
        _, log = machine.succeeds("cat #{Shellwords.escape(job[:log_path])}")

        expect(status).to eq("0"), "#{job[:name]} failed:\n#{log}"

        log
      end

      configure_examples do |config|
        config.default_order = :defined
      end

      ctid = get_container_id

      describe 'osctl ct console' do
        before(:context) do
          machine.wait_for_osctl_pool("tank")
          machine.wait_until_online
          machine.push_file("${consoleClient}", CONSOLE_CLIENT)
          machine.push_file(
            "${persistentConsoleClient}",
            PERSISTENT_CONSOLE_CLIENT
          )
          machine.push_file(
            "${resizeConsoleClient}",
            RESIZE_CONSOLE_CLIENT
          )

          machine.all_succeed(
            "osctl ct new --distribution alpine #{ctid}",
            "osctl ct unset start-menu #{ctid}",
            "osctl ct mount #{ctid}",
          )

          rootfs = output_of("osctl ct show -H -o rootfs #{ctid}")
          script_path = File.join(rootfs, "sbin", "console-test")
          machine.push_file("${containerInit}", script_path, preserve: true)

          machine.all_succeed(
            "osctl ct set init-cmd #{ctid} /sbin/console-test",
            "osctl ct start #{ctid}",
          )
          wait_ct_state(ctid, "running", timeout: 30)
        end

        after(:context) do
          machine.succeeds("osctl ct del --prune #{ctid}")
          machine.succeeds("osctl repository images prune")
        end

        it 'starts the container with the console test init' do
          expect(ct_state(ctid)).to eq("running")
        end

        it 'round-trips input before osctld restart' do
          output = console_roundtrip(ctid, "before-restart")

          expect(output).to include("CTCONSOLE_ECHO:before-restart")
        end

        it 'round-trips input after osctld restart' do
          restart_osctld
          expect(ct_state(ctid)).to eq("running")

          output = console_roundtrip(ctid, "after-restart")

          expect(output).to include("CTCONSOLE_ECHO:after-restart")
        end

        it 'propagates terminal resize to the container console' do
          output = console_resize(ctid, 37, 132)

          expect(output).to include("CTCONSOLE_SIZE:37 132")
        end

        it 'keeps an attached console open across clean stop and start' do
          dir = "/tmp/ct-console-persistent"
          paths = {
            ready: "#{dir}/ready",
            continue: "#{dir}/continue"
          }
          env = [
            "CTID=#{Shellwords.escape(ctid)}",
            "READY=#{Shellwords.escape(paths[:ready])}",
            "CONTINUE=#{Shellwords.escape(paths[:continue])}"
          ].join(' ')
          job = background_job(
            'persistent-console',
            <<~SH
              rm -rf #{Shellwords.escape(dir)}
              install -d -m 755 #{Shellwords.escape(dir)}
              #{env} ruby #{Shellwords.escape(PERSISTENT_CONSOLE_CLIENT)}
            SH
          )

          machine.wait_until_succeeds(
            "test -f #{Shellwords.escape(paths[:ready])}",
            timeout: 60
          )
          ready_output = output_of("cat #{Shellwords.escape(paths[:ready])}")
          expect(ready_output).to include("CTCONSOLE_ECHO:before-cycle")

          machine.succeeds("osctl ct stop #{ctid}")
          wait_ct_state(ctid, "stopped", timeout: 60)

          machine.succeeds("osctl ct start #{ctid}")
          wait_ct_state(ctid, "running", timeout: 60)

          machine.succeeds("touch #{Shellwords.escape(paths[:continue])}")
          log = wait_background_job(job, timeout: 90)

          expect(log).to include("CTCONSOLE_ECHO:before-cycle")
          expect(log).to include("CTCONSOLE_ECHO:after-cycle")
        end

        it 'stops cleanly' do
          machine.succeeds("osctl ct stop #{ctid}")
          wait_ct_state(ctid, "stopped", timeout: 60)

          expect(ct_state(ctid)).to eq("stopped")
        end
      end
    '';
  }
)
