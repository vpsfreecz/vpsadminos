{
  distribution,
  version,
  setupScript,
}:
import ../../make-test.nix (
  { pkgs }:
  {
    name = "docker-${distribution}-${version}";

    description = ''
      Test docker hello-world on ${distribution} ${version}
    '';

    tags = [ "ci" ];

    machine = import ../../machines/vpsadminos/tank.nix pkgs;

    testScript = ''
      require 'json'
      require 'shellwords'

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

      machine.start
      machine.wait_for_osctl_pool("tank")
      machine.wait_until_online

      machine.all_succeed(
        "osctl ct new --distribution ${distribution} --version ${version} docker",
        "osctl ct unset start-menu docker",
        "osctl ct netif new bridge --link lxcbr0 docker eth0",

        # TODO: why is this needed?
        "osctl ct set dns-resolver docker 1.1.1.1",

        "osctl ct start docker",
      )

      machine.wait_until_container_online('docker')

      ${setupScript}

      unless docker_registry_mirrors.empty?
        _, daemon_json = machine.succeeds("osctl ct exec docker cat /etc/docker/daemon.json")
        parsed_daemon_json = JSON.parse(daemon_json)

        unless parsed_daemon_json.fetch('registry-mirrors', []) == docker_registry_mirrors
          fail "unexpected docker registry mirrors: #{parsed_daemon_json.inspect}"
        end
      end

      st, output = machine.succeeds("osctl ct exec docker docker info")

      expected_storage_drivers = %w[overlay2 overlayfs]

      if /Storage Driver: ([^\s]+)\s/ =~ output
        unless expected_storage_drivers.include?($1.strip)
          fail "using '#{$1}' storage driver instead of one of #{expected_storage_drivers.join(', ')}"
        end
      else
        fail "unable to find storage driver in docker info, output:\n#{output}"
      end

      st, output = machine.succeeds("osctl ct exec docker docker run hello-world")

      if /Hello from Docker/ !~ output
        fail "docker hello-world not working, output:\n#{output}"
      end

      machine.succeeds("osctl ct exec docker docker pull gitlab/gitlab-ee:latest", timeout: 900)
      machine.succeeds("osctl ct exec docker docker image inspect gitlab/gitlab-ee:latest")
    '';
  }
)
