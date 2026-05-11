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
