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

      def docker_daemon_config(ct)
        status, output = machine.execute(
          "osctl ct exec #{ct} sh -c 'test -s /etc/docker/daemon.json && cat /etc/docker/daemon.json'",
          timeout: 60
        )
        status == 0 ? JSON.parse(output) : {}
      end

      def configure_docker_registry_mirrors(ct)
        mirrors = docker_registry_mirrors
        return if mirrors.empty?

        config = docker_daemon_config(ct)
        config['registry-mirrors'] = mirrors

        ct_write_file(
          ct,
          '/etc/docker/daemon.json',
          JSON.pretty_generate(config) + "\n"
        )
      end

      def dump_host_network_state(ct, label)
        escaped_ct = Shellwords.escape(ct)

        machine.succeeds(
          <<~SH,
            set -eu
            echo "=== host network state: #{label} #{ct} ==="
            echo "--- container"
            osctl ct show #{escaped_ct} || true
            osctl ct netif ls #{escaped_ct} || true
            osctl ct netif ip ls #{escaped_ct} || true
            osctl ct netif route ls #{escaped_ct} || true
            echo "--- lxcbr0"
            ip addr show lxcbr0 || true
            ip link show lxcbr0 || true
            echo "--- routes"
            ip route show || true
            ip -6 route show || true
            echo "--- dnsmasq"
            sv status lxcbr-dnsmasq || true
            pgrep -a dnsmasq || true
            echo "--- lxcbr-dnsmasq leases"
            cat /var/lib/lxcbr-dnsmasq/dnsmasq.leases 2>/dev/null || true
          SH
          timeout: 60
        )
      end

      def dump_container_network_state(ct, label)
        ct_shell(
          ct,
          <<~SH,
            set -eu
            echo "=== container network state: #{label} #{ct} ==="
            echo "--- /etc/resolv.conf"
            ls -l /etc/resolv.conf 2>/dev/null || true
            cat /etc/resolv.conf 2>/dev/null || true
            echo "--- addresses"
            ip addr show || true
            echo "--- routes"
            ip route show || true
            ip -6 route show || true
            echo "--- link"
            ip link show || true
            echo "--- resolver probe"
            getent hosts check-online.vpsadminos.org || true
            ping -c 1 1.1.1.1 || true
            ping -c 1 check-online.vpsadminos.org || true
          SH
          timeout: 60
        )
      end

      def docker_static_ipv4(distribution, version)
        key = "#{distribution}-#{version}"
        octet = 2 + key.bytes.sum % 98

        "192.168.1.#{octet}"
      end

      def create_docker_container(ct, distribution, version)
        ipv4 = docker_static_ipv4(distribution, version)

        machine.all_succeed(
          "osctl ct new --distribution #{distribution} --version #{version} #{ct}",
          "osctl ct unset start-menu #{ct}",
          "osctl ct netif new bridge --link lxcbr0 --no-dhcp --gateway-v4 auto --gateway-v6 none #{ct} eth0",
          "osctl ct netif ip add #{ct} eth0 #{ipv4}/24",

          # TODO: why is this needed?
          "osctl ct set dns-resolver #{ct} 1.1.1.1",

          "osctl ct start #{ct}",
        )

        machine.wait_until_container_online(ct)
      rescue OsVm::CommandFailed, OsVm::TimeoutError
        dump_host_network_state(ct, 'after online wait failure') rescue nil
        dump_container_network_state(ct, 'after online wait failure') rescue nil
        raise
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

      def docker_runtime_defaults_expected?
        %w[almalinux arch centos debian fedora rocky ubuntu].include?('${distribution}')
      end

      def check_docker(ct)
        if docker_runtime_defaults_expected? || !docker_registry_mirrors.empty?
          parsed_daemon_json = docker_daemon_config(ct)

          if docker_runtime_defaults_expected? &&
              !parsed_daemon_json.fetch('exec-opts', []).include?('native.cgroupdriver=cgroupfs')
            fail "docker cgroupfs default not present in daemon.json: #{parsed_daemon_json.inspect}"
          end

          if docker_runtime_defaults_expected? &&
              parsed_daemon_json.fetch('default-cgroupns-mode', nil) != 'host'
            fail "docker cgroup namespace default not present in daemon.json: #{parsed_daemon_json.inspect}"
          end

          unless docker_registry_mirrors.empty?
            unless parsed_daemon_json.fetch('registry-mirrors', []) == docker_registry_mirrors
              fail "unexpected docker registry mirrors: #{parsed_daemon_json.inspect}"
            end
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

        if /Cgroup Driver: ([^\s]+)\s/ =~ output
          if $1.strip != 'cgroupfs'
            fail "using '#{$1}' cgroup driver instead of cgroupfs"
          end
        else
          fail "unable to find cgroup driver in docker info, output:\n#{output}"
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
