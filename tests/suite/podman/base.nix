{
  distribution,
  tests,
}:
import ../../make-test.nix (
  { pkgs }:
  let
    common = ''
      require 'shellwords'

      def ensure_machine
        machine.start unless machine.running?
        machine.wait_for_osctl_pool('tank')
        machine.wait_until_online
      end

      def cleanup_container(ct)
        return unless machine.running?

        machine.succeeds("osctl ct del -f --prune #{ct}")
      rescue OsVm::CommandFailed
        # Best effort cleanup after failed setup.
      ensure
        begin
          machine.succeeds('osctl repository images prune') if machine.running?
        rescue OsVm::CommandFailed
          # Best effort cleanup after failed setup.
        end
      end

      def ct_shell(ct, script, timeout: 600)
        machine.succeeds(
          "osctl ct exec #{ct} sh -c #{Shellwords.escape(script)}",
          timeout:
        )
      end

      def ct_write_file(ct, path, contents)
        ct_shell(
          ct,
          <<~SH
            mkdir -p #{Shellwords.escape(File.dirname(path))}
            cat > #{Shellwords.escape(path)} <<'EOF'
            #{contents}
            EOF
          SH
        )
      end

      def podman_docker_io_mirrors
        Array(test_config.dig('podman', 'dockerIoMirrors'))
      end

      def podman_aliases
        test_config.dig('podman', 'aliases') || {}
      end

      def configure_podman_registry_mirrors(ct)
        mirrors = podman_docker_io_mirrors
        aliases = podman_aliases
        return if mirrors.empty? && aliases.empty?

        lines = []

        unless mirrors.empty?
          lines << '[[registry]]'
          lines << 'prefix = "docker.io"'
          lines << 'location = "docker.io"'
          lines << ""

          mirrors.each do |mirror|
            lines << '  [[registry.mirror]]'
            lines << %(  location = "#{mirror}")
            lines << '  pull-from-mirror = "all"'
            lines << ""
          end
        end

        unless aliases.empty?
          lines << '[aliases]'
          aliases.each do |short_name, image|
            lines << %(#{short_name.inspect} = #{image.inspect})
          end
          lines << ""
        end

        ct_write_file(
          ct,
          '/etc/containers/registries.conf.d/10-vpsadminos-mirror.conf',
          lines.join("\n")
        )
      end

      def create_podman_container(ct, distribution, version)
        machine.all_succeed(
          "osctl ct new --distribution #{distribution} --version #{version} #{ct}",
          "osctl ct unset start-menu #{ct}",
          "osctl ct netif new bridge --link lxcbr0 #{ct} eth0",

          # Podman builds use pasta for build container networking by default,
          # which needs /dev/net/tun.
          "osctl ct devices add -p #{ct} char 10 200 rwm /dev/net/tun",

          # TODO: why is this needed?
          "osctl ct set dns-resolver #{ct} 1.1.1.1",

          "osctl ct start #{ct}",
        )

        machine.wait_until_container_online(ct)
      end

      def resource_limit_cases
        [
          {
            name: 'mem64-cpu0_5',
            memory: '64m',
            memory_bytes: 64 * 1024 * 1024,
            cpuset_cpus: '0',
            cpu_quota: 50_000,
          },
          {
            name: 'mem128-cpu1',
            memory: '128m',
            memory_bytes: 128 * 1024 * 1024,
            cpuset_cpus: '0',
            cpu_quota: 100_000,
          },
          {
            name: 'mem256-cpu2',
            memory: '256m',
            memory_bytes: 256 * 1024 * 1024,
            cpuset_cpus: '0-1',
            cpu_quota: 200_000,
          },
        ]
      end

      def resource_limits_script(memory_bytes:, cpu_quota:)
        <<~SH
          set -eu

          expected_memory=#{memory_bytes}
          expected_cpu_quota=#{cpu_quota}
          expected_cpu_period=100000

          if [ -f /sys/fs/cgroup/cgroup.controllers ]; then
            current_cgroup=$(awk -F: '$1 == "0" { print $3 }' /proc/self/cgroup)
            actual_memory=$(cat "/sys/fs/cgroup$current_cgroup/memory.max")
          elif [ -f /sys/fs/cgroup/memory/memory.limit_in_bytes ]; then
            current_memory_cgroup=$(awk -F: '$2 ~ /(^|,)memory(,|$)/ { print $3 }' /proc/self/cgroup)
            actual_memory=$(cat "/sys/fs/cgroup/memory$current_memory_cgroup/memory.limit_in_bytes")
          else
            echo "memory limit file not found" >&2
            exit 1
          fi

          if [ "$actual_memory" != "$expected_memory" ]; then
            echo "expected memory limit $expected_memory, got $actual_memory" >&2
            exit 1
          fi

          if [ -f /sys/fs/cgroup/cgroup.controllers ]; then
            set -- $(cat "/sys/fs/cgroup$current_cgroup/cpu.max")
            actual_cpu_quota=$1
            actual_cpu_period=$2
          elif [ -f /sys/fs/cgroup/cpu,cpuacct/cpu.cfs_quota_us ]; then
            current_cpu_cgroup=$(awk -F: '$2 ~ /(^|,)cpu(,|$)/ { print $3 }' /proc/self/cgroup)
            actual_cpu_quota=$(cat "/sys/fs/cgroup/cpu,cpuacct$current_cpu_cgroup/cpu.cfs_quota_us")
            actual_cpu_period=$(cat "/sys/fs/cgroup/cpu,cpuacct$current_cpu_cgroup/cpu.cfs_period_us")
          elif [ -f /sys/fs/cgroup/cpu/cpu.cfs_quota_us ]; then
            current_cpu_cgroup=$(awk -F: '$2 ~ /(^|,)cpu(,|$)/ { print $3 }' /proc/self/cgroup)
            actual_cpu_quota=$(cat "/sys/fs/cgroup/cpu$current_cpu_cgroup/cpu.cfs_quota_us")
            actual_cpu_period=$(cat "/sys/fs/cgroup/cpu$current_cpu_cgroup/cpu.cfs_period_us")
          else
            echo "CPU limit file not found" >&2
            exit 1
          fi

          if [ "$actual_cpu_quota" != "$expected_cpu_quota" ] \
            || [ "$actual_cpu_period" != "$expected_cpu_period" ]; then
            echo "expected CPU limit $expected_cpu_quota $expected_cpu_period, got $actual_cpu_quota $actual_cpu_period" >&2
            exit 1
          fi

          echo "resource limits work"
        SH
      end

      def check_podman_resource_limits(ct)
        resource_limit_cases.each do |limit|
          container = "resource-limit-#{limit.fetch(:name)}"

          begin
            ct_shell(ct, "podman rm -f #{container} >/dev/null 2>&1 || true")

            script = resource_limits_script(
              memory_bytes: limit.fetch(:memory_bytes),
              cpu_quota: limit.fetch(:cpu_quota)
            )

            ct_shell(
              ct,
              "podman create --name #{container} --memory #{limit.fetch(:memory)} " \
                "--cpu-period 100000 --cpu-quota #{limit.fetch(:cpu_quota)} " \
                "--cpuset-cpus #{limit.fetch(:cpuset_cpus)} " \
                "localhost/podman-build-test:latest " \
                "sh -c #{Shellwords.escape(script)}"
            )

            _, output = ct_shell(ct, "podman start --attach #{container}")

            unless output.include?('resource limits work')
              fail "podman resource limits check #{limit.fetch(:name)} produced unexpected output:\n#{output}"
            end
          ensure
            ct_shell(ct, "podman rm -f #{container} >/dev/null 2>&1 || true")
          end
        end
      end

      def check_podman(ct)
        unless podman_docker_io_mirrors.empty? && podman_aliases.empty?
          _, registries_conf = machine.succeeds(
            "osctl ct exec #{ct} cat /etc/containers/registries.conf.d/10-vpsadminos-mirror.conf"
          )

          podman_docker_io_mirrors.each do |mirror|
            unless registries_conf.include?(%{location = "#{mirror}"})
              fail "podman mirror #{mirror.inspect} not present in registries.conf drop-in"
            end
          end

          podman_aliases.each do |short_name, image|
            unless registries_conf.include?(%{"#{short_name}" = "#{image}"})
              fail "podman alias #{short_name.inspect} not present in registries.conf drop-in"
            end
          end
        end

        _, output = machine.succeeds("osctl ct exec #{ct} podman info")

        if /graphDriverName: ([^\s]+)\s/ =~ output
          if $1.strip != 'overlay'
            fail "using '#{$1}' storage driver instead of overlay"
          end
        else
          fail "unable to find storage driver in podman info, output:\n#{output}"
        end

        if /cgroupManager: ([^\s]+)\s/ =~ output
          if $1.strip != 'cgroupfs'
            fail "using '#{$1}' cgroup manager instead of cgroupfs"
          end
        else
          fail "unable to find cgroup manager in podman info, output:\n#{output}"
        end

        _, output = machine.succeeds("osctl ct exec #{ct} podman run hello-world")

        # Some distros/podman versions fetch hello-world from different registries.
        # On Fedora we get podman's hello world and on Debian and Ubuntu we get
        # docker's hello world...
        if /Hello Podman World/ !~ output && /Hello from Docker/ !~ output
          fail "podman hello-world not working, output:\n#{output}"
        end

        ct_write_file(
          ct,
          '/tmp/podman-build-test/Dockerfile',
          <<~DOCKERFILE
            FROM docker.io/library/alpine:latest
            RUN echo "Podman build works!" > /message.txt
            CMD ["cat", "/message.txt"]
          DOCKERFILE
        )

        ct_shell(
          ct,
          'podman build -t localhost/podman-build-test:latest /tmp/podman-build-test',
          timeout: 600
        )

        _, output = machine.succeeds(
          "osctl ct exec #{ct} podman run --rm localhost/podman-build-test:latest"
        )

        if output.strip != 'Podman build works!'
          fail "podman build produced unexpected output:\n#{output}"
        end

        check_podman_resource_limits(ct)
      end
    '';
  in
  {
    name = "podman-${distribution}";

    description = ''
      Test Podman on ${distribution}
    '';

    tags = [ "ci" ];

    machine = import ../../machines/vpsadminos/tank.nix pkgs;

    testScripts = builtins.listToAttrs (
      map (test: {
        name = test.version;
        value = {
          description = ''
            Test Podman on ${distribution} ${test.version}
          '';
          script = common + ''
            ct = get_container_id('podman')

            begin
              ensure_machine
              create_podman_container(ct, '${distribution}', '${test.version}')
              ${test.setup}
              check_podman(ct)
            ensure
              cleanup_container(ct)
            end
          '';
        };
      }) tests
    );
  }
)
