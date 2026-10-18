import ../../make-test.nix (
  { pkgs }:
  let
    helperProbe = pkgs.writeText "switch-user-prlimits.rb" ''
      require 'digest'
      require 'etc'
      require 'fcntl'
      require 'json'
      require 'timeout'
      require 'osctld'

      OsCtl::Lib::Logger.setup(:none)

      source = OsCtld::SwitchUser.method(:fork_and_switch_to).source_location.fetch(0)
      packaged_source = File.join(Gem.loaded_specs.fetch('osctld').full_gem_path, 'lib/osctld/switch_user.rb')
      expected = '${builtins.hashFile "sha256" ../../../osctld/lib/osctld/switch_user.rb}'
      abort "helper loaded outside its package: #{source}" unless File.identical?(source, packaged_source)
      abort "unexpected packaged helper: #{source}" unless Digest::SHA256.file(source).hexdigest == expected

      OsCtld::CGroup.init
      Process.setrlimit(:NOFILE, 8192, 8192)
      inherited = Array.new(1200) { File.open(File::NULL) }
      reader, writer = IO.pipe
      preparation = nil

      # Observe the real child's inherited descriptors before the packaged
      # implementation closes them. Do not replace cleanup or limit handling.
      observer = Module.new do
        define_method(:close_fds) do |**opts|
          preparation = {
            inherited_fds: inherited.count { |io| io.fcntl(Fcntl::F_GETFD) >= 0 },
            nofile: Process.getrlimit(:NOFILE)
          }
          super(**opts)
        end
      end
      OsCtld::SwitchUser.singleton_class.prepend(observer)

      account = Etc.getpwnam('nobody')
      cgroup = 'osctl/switch-user-prlimits'
      pid = nil

      begin
        Timeout.timeout(30) do
          pid = OsCtld::SwitchUser.fork_and_switch_to(
            account.name, account.uid, account.dir, cgroup,
            chown_cgroups: false,
            keep_fds: [writer],
            prlimits: { 'nofile' => { soft: 1024, hard: 8192 } }
          ) do
            writer.puts(JSON.generate({
              preparation: preparation,
              nofile: Process.getrlimit(:NOFILE),
              uid: Process.uid,
              open_fds: Dir.children('/proc/self/fd').length,
              source: source,
              sha256: expected
            }))
            writer.close
            exit!(0)
          end

          writer.close
          result = JSON.parse(reader.readline)
          _, status = Process.wait2(pid)
          pid = nil
          abort "helper failed: #{status.inspect}" unless status.success?
          abort "identity did not change: #{result.inspect}" unless result.fetch('uid') == account.uid
          puts JSON.generate(result)
        end
      ensure
        if pid
          begin
            Process.kill('KILL', pid)
            Process.wait(pid)
          rescue Errno::ESRCH, Errno::ECHILD
            # The helper may have already exited or been reaped on failure.
          end
        end
        ([reader, writer] + inherited).each { |io| io.close unless io.closed? }
        OsCtld::CGroup.subsystems.each do |subsystem|
          path = OsCtld::CGroup.abs_cgroup_path(subsystem, cgroup)
          Dir.rmdir(path) if Dir.exist?(path)
        end
      end
    '';

    consoleClient = pkgs.writeText "switch-user-console.rb" ''
      require 'pty'
      require 'timeout'

      output = String.new
      PTY.spawn('osctl', 'ct', 'console', ARGV.fetch(0)) do |reader, writer, pid|
        begin
          Timeout.timeout(20) do
            output << reader.readpartial(4096) until output.include?('Press Ctrl+a q')
            writer.write("prlimit-console\n")
            output << reader.readpartial(4096) until output.include?('PRLIMIT_ECHO:prlimit-console')
          end
          writer.write("\x01q")
          _, status = Timeout.timeout(10) { Process.wait2(pid) }
          abort "console failed: #{status.inspect}" unless status.success?
          puts output
        rescue Exception
          warn output
          Process.kill('KILL', pid) rescue nil
          Process.wait(pid) rescue nil
          raise
        end
      end
    '';

    containerInit = pkgs.writeScript "switch-user-console-init" ''
      #!/bin/sh
      trap 'exit 0' TERM INT HUP PWR
      while IFS= read -r line; do
        echo "PRLIMIT_ECHO:$line"
      done
    '';
  in
  {
    name = "osctld-switch-user-prlimits";
    description = "Prepare inherited descriptors before applying container process limits";
    tags = [ "ci" ];

    machine = import ../../machines/vpsadminos/with-tank.nix {
      inherit pkgs;
      config =
        { pkgs, ... }:
        {
          osctl.pools.tank.parallelStart = 2;
          environment.etc = {
            "switch-user-prlimits.rb".source = helperProbe;
            "switch-user-console.rb".source = consoleClient;
            # Use the guest module's overlaid packages, exactly as its daemon
            # service does. The test evaluator's pkgs only has tool overlays.
            "switch-user-prlimits".source = pkgs.writeShellScript "switch-user-prlimits" ''
              export GEM_HOME=${pkgs.osctld.basicEnv}/${pkgs.ruby_vpsadminos.gemPath}
              export GEM_PATH=${pkgs.osctld.basicEnv}/${pkgs.ruby_vpsadminos.gemPath}
              exec ${pkgs.ruby_vpsadminos}/bin/ruby /etc/switch-user-prlimits.rb
            '';
            "switch-user-console".source = pkgs.writeShellScript "switch-user-console" ''
              exec ${pkgs.ruby_vpsadminos}/bin/ruby /etc/switch-user-console.rb "$@"
            '';
          };
        };
    };

    testScript = ''
      require 'json'
      require 'shellwords'

      configure_examples do |config|
        config.default_order = :defined
      end

      containers = %w[prlimit-first prlimit-second]

      describe 'packaged SwitchUser preparation and container autostart' do
        before(:context) do
          machine.wait_for_osctl_pool('tank')
          machine.wait_until_online
        end

        after(:context) do
          machine.execute('tail -n 100 /var/log/osctld')
          containers.each do |ct|
            machine.execute("osctl ct stop #{ct}")
            machine.execute("osctl ct del --prune #{ct}")
          end
        end

        it 'cleans more than 1024 inherited descriptors before lowering the actual child limit' do
          _, output = machine.succeeds('/etc/switch-user-prlimits', timeout: 60)
          result = JSON.parse(output)

          expect(result.fetch('preparation').fetch('inherited_fds')).to eq(1200)
          expect(result.fetch('preparation').fetch('nofile')).to eq([8192, 8192])
          expect(result.fetch('nofile')).to eq([1024, 8192])
          expect(result.fetch('open_fds')).to be < 1024
          expect(result.fetch('source')).to start_with('/nix/store/')
        end

        it 'autostarts two containers in a parallel pool and preserves their configured limits' do
          containers.each do |ct|
            machine.all_succeed(
              "osctl ct new --distribution alpine #{ct}",
              "osctl ct unset start-menu #{ct}",
              "osctl ct prlimits set #{ct} nofile 1024 8192",
              "osctl ct set autostart --delay 0 #{ct}",
              "osctl ct mount #{ct}"
            )
            rootfs = machine.osctl_json("ct show #{ct}").fetch('rootfs')
            machine.push_file('${containerInit}', "#{rootfs}/sbin/prlimit-console", preserve: true)
            machine.succeeds("osctl ct set init-cmd #{ct} /sbin/prlimit-console")
          end

          machine.all_succeed('osctl pool export tank', 'osctl pool import tank')
          machine.wait_for_osctl_pool('tank')
          expect(machine.osctl_json('pool show tank').fetch('parallel_start')).to eq(2)

          containers.each do |ct|
            machine.wait_until_succeeds(
              "test \"$(osctl ct show -H -o state #{ct})\" = running",
              timeout: 120
            )
            info = machine.osctl_json("ct show #{ct}")
            expect(info.fetch('state')).to eq('running')
            _, limits = machine.succeeds("cat /proc/#{Integer(info.fetch('init_pid'))}/limits")
            nofile = limits.lines.find { |line| line.start_with?('Max open files') }
            expect(nofile.split[3, 2].map(&:to_i)).to eq([1024, 8192])
          end
        end

        it 'supports exec and console and stops both containers cleanly' do
          containers.each do |ct|
            _, output = machine.succeeds("osctl ct exec #{ct} sh -c 'printf PRLIMIT_EXEC'")
            expect(output).to eq('PRLIMIT_EXEC')
            _, output = machine.succeeds(
              "/etc/switch-user-console #{ct}",
              timeout: 40
            )
            expect(output).to include('PRLIMIT_ECHO:prlimit-console')
            machine.succeeds("osctl ct stop #{ct}", timeout: 120)
            expect(machine.osctl_json("ct show #{ct}").fetch('state')).to eq('stopped')
          end

          _, log = machine.succeeds('cat /var/log/osctld')
          # Closing these stopped containers' console backends normally logs EOF.
          unexpected = log.lines.reject do |line|
            line.match?(/\[ct=tank:prlimit-(?:first|second)\] Closing TTY 0 \(EOFError: end of file reached\)\s*\z/)
          end.join
          expect(unexpected).not_to match(/Too many open files|Errno::EMFILE|end of file reached|EOFError/)
        end
      end
    '';
  }
)
