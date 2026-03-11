{
  distribution,
  version,
  setupScript,
}:
import ../../make-test.nix (
  { pkgs }:
  {
    name = "podman-${distribution}-${version}";

    description = ''
      Test podman hello-world on ${distribution} ${version}
    '';

    tags = [ "ci" ];

    machine = import ../../machines/vpsadminos/tank.nix pkgs;

    testScript = ''
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

      machine.start
      machine.wait_for_osctl_pool("tank")
      machine.wait_until_online

      machine.all_succeed(
        "osctl ct new --distribution ${distribution} --version ${version} podmanct",
        "osctl ct unset start-menu podmanct",
        "osctl ct netif new bridge --link lxcbr0 podmanct eth0",

        # TODO: why is this needed?
        "osctl ct set dns-resolver podmanct 1.1.1.1",

        "osctl ct start podmanct",
      )

      machine.wait_until_container_online('podmanct')

      ${setupScript}

      unless podman_docker_io_mirrors.empty? && podman_aliases.empty?
        _, registries_conf = machine.succeeds(
          "osctl ct exec podmanct cat /etc/containers/registries.conf.d/10-vpsadminos-mirror.conf"
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

      st, output = machine.succeeds("osctl ct exec podmanct podman info")

      if /graphDriverName: ([^\s]+)\s/ =~ output
        if $1.strip != 'overlay'
          fail "using '#{$1}' storage driver instead of overlay"
        end
      else
        fail "unable to find storage driver in podman info, output:\n#{output}"
      end

      st, output = machine.succeeds("osctl ct exec podmanct podman run hello-world")

      # Some distros/podman versions fetch hello-world from different registries.
      # On Fedora we get podman's hello world and on Debian and Ubuntu we get
      # docker's hello world...
      if /Hello Podman World/ !~ output && /Hello from Docker/ !~ output
        fail "podman hello-world not working, output:\n#{output}"
      end
    '';
  }
)
