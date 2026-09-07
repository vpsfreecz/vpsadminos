{
  distribution,
  tests,
}:
import ../../make-test.nix (
  { pkgs }:
  let
    common = ''
      require 'json'
      require 'shellwords'

      def ensure_machine
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

      def docker_registry_mirrors
        Array(test_config.dig('docker', 'registryMirrors'))
      end

      def configure_docker_registry_mirrors(ct)
        mirrors = docker_registry_mirrors
        return if mirrors.empty?

        ct_write_file(
          ct,
          '/etc/docker/daemon.json',
          JSON.pretty_generate('registry-mirrors' => mirrors) + "\n"
        )
      end

      def create_docker_container(ct, distribution, version)
        machine.all_succeed(
          "osctl ct new --distribution #{distribution} --version #{version} #{ct}",
          "osctl ct unset start-menu #{ct}",
          "osctl ct netif new bridge --link lxcbr0 #{ct} eth0",

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

          if [ -f /sys/fs/cgroup/memory.max ]; then
            actual_memory=$(cat /sys/fs/cgroup/memory.max)
          elif [ -f /sys/fs/cgroup/memory/memory.limit_in_bytes ]; then
            actual_memory=$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes)
          else
            echo "memory limit file not found" >&2
            exit 1
          fi

          if [ "$actual_memory" != "$expected_memory" ]; then
            echo "expected memory limit $expected_memory, got $actual_memory" >&2
            exit 1
          fi

          if [ -f /sys/fs/cgroup/cpu.max ]; then
            set -- $(cat /sys/fs/cgroup/cpu.max)
            actual_cpu_quota=$1
            actual_cpu_period=$2
          elif [ -f /sys/fs/cgroup/cpu,cpuacct/cpu.cfs_quota_us ]; then
            actual_cpu_quota=$(cat /sys/fs/cgroup/cpu,cpuacct/cpu.cfs_quota_us)
            actual_cpu_period=$(cat /sys/fs/cgroup/cpu,cpuacct/cpu.cfs_period_us)
          elif [ -f /sys/fs/cgroup/cpu/cpu.cfs_quota_us ]; then
            actual_cpu_quota=$(cat /sys/fs/cgroup/cpu/cpu.cfs_quota_us)
            actual_cpu_period=$(cat /sys/fs/cgroup/cpu/cpu.cfs_period_us)
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

      def check_docker_resource_limits(ct)
        resource_limit_cases.each do |limit|
          container = "resource-limit-#{limit.fetch(:name)}"

          begin
            ct_shell(ct, "docker rm -f #{container} >/dev/null 2>&1 || true")

            script = resource_limits_script(
              memory_bytes: limit.fetch(:memory_bytes),
              cpu_quota: limit.fetch(:cpu_quota)
            )

            ct_shell(
              ct,
              "docker create --name #{container} --memory #{limit.fetch(:memory)} " \
                "--cpu-period 100000 --cpu-quota #{limit.fetch(:cpu_quota)} " \
                "--cpuset-cpus #{limit.fetch(:cpuset_cpus)} " \
                "docker-build-test " \
                "sh -c #{Shellwords.escape(script)}"
            )

            _, output = ct_shell(ct, "docker start --attach #{container}")

            unless output.include?('resource limits work')
              fail "docker resource limits check #{limit.fetch(:name)} produced unexpected output:\n#{output}"
            end
          ensure
            ct_shell(ct, "docker rm -f #{container} >/dev/null 2>&1 || true")
          end
        end
      end

      def check_docker(ct)
        unless docker_registry_mirrors.empty?
          _, daemon_json = machine.succeeds("osctl ct exec #{ct} cat /etc/docker/daemon.json")
          parsed_daemon_json = JSON.parse(daemon_json)

          unless parsed_daemon_json.fetch('registry-mirrors', []) == docker_registry_mirrors
            fail "unexpected docker registry mirrors: #{parsed_daemon_json.inspect}"
          end
        end

        _, output = machine.succeeds("osctl ct exec #{ct} docker info")

        expected_storage_drivers = %w[overlay2 overlayfs]

        if /Storage Driver: ([^\s]+)\s/ =~ output
          unless expected_storage_drivers.include?($1.strip)
            fail "using '#{$1}' storage driver instead of one of #{expected_storage_drivers.join(', ')}"
          end
        else
          fail "unable to find storage driver in docker info, output:\n#{output}"
        end

        _, output = machine.succeeds("osctl ct exec #{ct} docker run hello-world")

        if /Hello from Docker/ !~ output
          fail "docker hello-world not working, output:\n#{output}"
        end

        ct_write_file(
          ct,
          '/tmp/docker-build-test/Dockerfile',
          <<~DOCKERFILE
            # syntax=docker/dockerfile:1

            FROM alpine:latest
            RUN echo "Docker build works!" > /message.txt
            CMD ["cat", "/message.txt"]
          DOCKERFILE
        )

        ct_shell(
          ct,
          'docker build -t docker-build-test /tmp/docker-build-test',
          timeout: 600
        )

        _, output = machine.succeeds("osctl ct exec #{ct} docker run --rm docker-build-test")

        if output.strip != 'Docker build works!'
          fail "docker build produced unexpected output:\n#{output}"
        end

        check_docker_resource_limits(ct)

        machine.succeeds("osctl ct exec #{ct} docker pull gitlab/gitlab-ee:latest", timeout: 900)
        machine.succeeds("osctl ct exec #{ct} docker image inspect gitlab/gitlab-ee:latest")
      end
    '';
  in
  {
    name = "docker-${distribution}";

    description = ''
      Test Docker on ${distribution}
    '';

    tags = [ "ci" ];

    machine = import ../../machines/vpsadminos/tank.nix pkgs;

    testScripts = builtins.listToAttrs (
      map (test: {
        name = test.version;
        value = {
          description = ''
            Test Docker on ${distribution} ${test.version}
          '';
          script = common + ''
            ct = get_container_id('docker')

            begin
              ensure_machine
              create_docker_container(ct, '${distribution}', '${test.version}')
              ${test.setup}
              check_docker(ct)
            ensure
              cleanup_container(ct)
            end
          '';
        };
      }) tests
    );
  }
)
