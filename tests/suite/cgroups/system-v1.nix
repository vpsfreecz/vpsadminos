import ../../make-test.nix (
  { pkgs }:
  {
    name = "cgroups-system-v1";

    description = ''
      Test cgroupv1 configuration
    '';

    tags = [ "ci" ];

    machines = {
      # Enable cgroupv1 by default
      config_cgroup = import ../../machines/vpsadminos/with-empty.nix {
        inherit pkgs;
        config =
          { config, ... }:
          {
            boot.enableUnifiedCgroupHierarchy = false;
          };
      };

      # We set the default to cgroupv2, but expect it to start with cgroupv1
      runtime_cgroup = import ../../machines/vpsadminos/with-empty.nix {
        inherit pkgs;
        config =
          { config, ... }:
          {
            boot.enableUnifiedCgroupHierarchy = true;
          };
      };
    };

    testScript = ''
      config_cgroup.start
      runtime_cgroup.start(kernel_params: ['osctl.cgroupv=1'])

      machines.each do |name, machine|
        _, output = machine.succeeds('cat /run/osctl/cgroup.version')
        if output.strip != "1"
          fail "expected cgroup version on #{name} to be 1, got '#{output.inspect}'"
        end

        machine.all_succeed(
          'cat /sys/fs/cgroup/cpuset/cgroup.procs',
          'cat /sys/fs/cgroup/unified/cgroup.procs',
        )
      end

      # A remote cgroup writer must not turn a valid, in-flight task authority
      # transition into EACCES when the moved task opens a cgroup file.
      config_cgroup.succeeds(<<~'SH', timeout: 60)
        ruby -rjson - <<'RB'
        clock = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
        mount = File.readlines('/proc/mounts').map(&:split).find do |fields|
          fields[2] == 'cgroup' && fields[3].split(',').include?('devices')
        end
        raise 'devices v1 mount missing' unless mount

        root = mount[1]
        dirs = %w[a b].map { |name| File.join(root, "open-race-#{Process.pid}-#{name}") }
        dirs.each { |dir| Dir.mkdir(dir) }
        reader, writer = IO.pipe
        deadline = clock.call + 5
        child = fork do
          reader.close
          opens = Hash.new(0)
          while clock.call < deadline
            begin
              File.open(File.join(root, 'cgroup.procs'), 'r') { |file| file.fileno }
              opens['ok'] += 1
            rescue SystemCallError => e
              opens["errno_#{e.errno}"] += 1
            end
          end
          writer.write(JSON.generate(opens))
          writer.close
          exit! 0
        end
        writer.close
        moves = Hash.new(0)
        files = dirs.map { |dir| File.open(File.join(dir, 'cgroup.procs'), 'w') }
        begin
          while clock.call < deadline
            files.each do |file|
              begin
                file.syswrite(child.to_s)
                moves['ok'] += 1
              rescue SystemCallError => e
                moves["errno_#{e.errno}"] += 1
              end
            end
          end
        ensure
          files.each(&:close)
        end
        opens = JSON.parse(reader.read)
        _, status = Process.wait2(child)
        dirs.each { |dir| Dir.rmdir(dir) }
        puts JSON.generate(open: opens, migration: moves)
        raise 'reader failed' unless status.success?
        raise 'migration did not exercise the race' unless moves['ok'] >= 1000
        raise 'cgroup open did not run' unless opens.fetch('ok', 0) >= 1000
        raise 'cgroup open denied during valid migration' if opens.keys.any? { |key| key != 'ok' }
        RB
      SH
    '';
  }
)
