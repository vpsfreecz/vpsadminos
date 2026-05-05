import ../make-test.nix (
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

          # TODO: why is this needed?
          "osctl ct set dns-resolver #{ct} 1.1.1.1",

          "osctl ct start #{ct}",
        )

        machine.wait_until_container_online(ct)
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

        _, output = machine.succeeds("osctl ct exec #{ct} podman run hello-world")

        # Some distros/podman versions fetch hello-world from different registries.
        # On Fedora we get podman's hello world and on Debian and Ubuntu we get
        # docker's hello world...
        if /Hello Podman World/ !~ output && /Hello from Docker/ !~ output
          fail "podman hello-world not working, output:\n#{output}"
        end
      end
    '';

    tests = [
      {
        name = "debian-latest";
        distribution = "debian";
        version = "latest";
        setup = ''
          machine.all_succeed(
            "osctl ct exec #{ct} apt-get -y update",
            "osctl ct exec #{ct} apt-get -y install podman",
          )

          configure_podman_registry_mirrors(ct)
        '';
      }
      {
        name = "fedora-latest";
        distribution = "fedora";
        version = "latest";
        setup = ''
          machine.all_succeed(
            "osctl ct exec #{ct} dnf -y update",
            "osctl ct exec #{ct} dnf -y install podman",
          )

          configure_podman_registry_mirrors(ct)
        '';
      }
      {
        name = "ubuntu-latest";
        distribution = "ubuntu";
        version = "latest";
        setup = ''
          machine.all_succeed(
            "osctl ct exec #{ct} apt-get -y update",
            "osctl ct exec #{ct} apt-get -y install podman",
          )

          configure_podman_registry_mirrors(ct)
        '';
      }
    ];
  in
  {
    name = "podman";

    description = ''
      Test Podman in containers
    '';

    tags = [ "ci" ];

    machine = import ../machines/vpsadminos/tank.nix pkgs;

    testScripts = builtins.listToAttrs (
      map (test: {
        name = test.name;
        value = {
          description = ''
            Test Podman on ${test.distribution} ${test.version}
          '';
          script = common + ''
            ct = get_container_id('podman')

            begin
              ensure_machine
              create_podman_container(ct, '${test.distribution}', '${test.version}')
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
