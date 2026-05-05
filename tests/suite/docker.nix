import ../make-test.nix (
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

        machine.succeeds("osctl ct exec #{ct} docker pull gitlab/gitlab-ee:latest", timeout: 900)
        machine.succeeds("osctl ct exec #{ct} docker image inspect gitlab/gitlab-ee:latest")
      end
    '';

    tests = [
      {
        name = "almalinux-8";
        distribution = "almalinux";
        version = "8";
        setup = ''
          machine.all_succeed(
            "osctl ct exec #{ct} yum update -y",
            "osctl ct exec #{ct} yum install -y yum-utils",
            "osctl ct exec #{ct} yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo",
            "osctl ct exec #{ct} yum install -y docker-ce docker-ce-cli containerd.io",
          )

          configure_docker_registry_mirrors(ct)
          machine.succeeds("osctl ct exec #{ct} systemctl start docker")
        '';
      }
      {
        name = "almalinux-9";
        distribution = "almalinux";
        version = "9";
        setup = ''
          machine.all_succeed(
            "osctl ct exec #{ct} yum update -y",
            "osctl ct exec #{ct} yum install -y yum-utils",
            "osctl ct exec #{ct} yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo",
            "osctl ct exec #{ct} yum install -y docker-ce docker-ce-cli containerd.io",
          )

          configure_docker_registry_mirrors(ct)
          machine.succeeds("osctl ct exec #{ct} systemctl start docker")
        '';
      }
      {
        name = "almalinux-10";
        distribution = "almalinux";
        version = "10";
        setup = ''
          machine.all_succeed(
            "osctl ct exec #{ct} yum update -y",
            "osctl ct exec #{ct} yum install -y yum-utils",
            "osctl ct exec #{ct} yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo",
            "osctl ct exec #{ct} yum install -y docker-ce docker-ce-cli containerd.io",
          )

          configure_docker_registry_mirrors(ct)
          machine.succeeds("osctl ct exec #{ct} systemctl start docker")
        '';
      }
      {
        name = "alpine-latest";
        distribution = "alpine";
        version = "latest";
        setup = ''
          machine.all_succeed(
            "osctl ct exec #{ct} apk update",
            "osctl ct exec #{ct} apk add docker",
          )

          configure_docker_registry_mirrors(ct)
          machine.succeeds("osctl ct exec #{ct} service docker start")
        '';
      }
      {
        name = "arch-latest";
        distribution = "arch";
        version = "latest";
        setup = ''
          machine.all_succeed(
            "osctl ct exec #{ct} pacman -Syu --noconfirm docker",
            "osctl ct exec #{ct} systemctl enable docker.service",
          )

          configure_docker_registry_mirrors(ct)
          machine.succeeds("osctl ct exec #{ct} systemctl start docker.service")
        '';
      }
      {
        name = "debian-latest";
        distribution = "debian";
        version = "latest";
        setup = ''
          machine.all_succeed(
            "osctl ct exec #{ct} apt-get update -y",
            "osctl ct exec #{ct} apt-get -y install ca-certificates curl",
            "osctl ct exec #{ct} curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc",
            "osctl ct exec #{ct} chmod a+r /etc/apt/keyrings/docker.asc",
            "osctl ct exec #{ct} bash -c 'echo \"deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $(. /etc/os-release && echo $VERSION_CODENAME) stable\" > /etc/apt/sources.list.d/docker.list'",
            "osctl ct exec #{ct} apt-get update -y",
            "osctl ct exec #{ct} apt-get -y install docker-ce docker-ce-cli containerd.io",
          )

          configure_docker_registry_mirrors(ct)
          machine.succeeds("osctl ct exec #{ct} systemctl restart docker")
        '';
      }
      {
        name = "fedora-latest";
        distribution = "fedora";
        version = "latest";
        setup = ''
          machine.all_succeed(
            "osctl ct exec #{ct} dnf -y update",
            "osctl ct exec #{ct} dnf -y install dnf-plugins-core",
            "osctl ct exec #{ct} dnf-3 config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo",
            "osctl ct exec #{ct} dnf -y install docker-ce docker-ce-cli containerd.io",
          )

          configure_docker_registry_mirrors(ct)
          machine.succeeds("osctl ct exec #{ct} systemctl start docker")
        '';
      }
      {
        name = "ubuntu-20.04";
        distribution = "ubuntu";
        version = "20.04";
        setup = ''
          machine.all_succeed(
            "osctl ct exec #{ct} apt-get update -y",
            "osctl ct exec #{ct} apt-get -y install apt-transport-https ca-certificates curl software-properties-common",
            "osctl ct exec #{ct} bash -c \"curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add -\"",
            "osctl ct exec #{ct} add-apt-repository \"deb [arch=amd64] https://download.docker.com/linux/ubuntu focal stable\"",
            "osctl ct exec #{ct} apt-get update -y",
            "osctl ct exec #{ct} apt-get -y install docker-ce",
          )

          configure_docker_registry_mirrors(ct)
          machine.succeeds("osctl ct exec #{ct} systemctl restart docker")
        '';
      }
      {
        name = "ubuntu-22.04";
        distribution = "ubuntu";
        version = "22.04";
        setup = ''
          machine.all_succeed(
            "osctl ct exec #{ct} apt-get update -y",
            "osctl ct exec #{ct} apt-get -y install apt-transport-https ca-certificates curl software-properties-common",
            "osctl ct exec #{ct} bash -c \"curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add -\"",
            "osctl ct exec #{ct} add-apt-repository \"deb [arch=amd64] https://download.docker.com/linux/ubuntu focal stable\"",
            "osctl ct exec #{ct} apt-get update -y",
            "osctl ct exec #{ct} apt-get -y install docker-ce",
          )

          configure_docker_registry_mirrors(ct)
          machine.succeeds("osctl ct exec #{ct} systemctl restart docker")
        '';
      }
      {
        name = "ubuntu-24.04";
        distribution = "ubuntu";
        version = "24.04";
        setup = ''
          machine.all_succeed(
            "osctl ct exec #{ct} apt-get update -y",
            "osctl ct exec #{ct} apt-get -y install apt-transport-https ca-certificates curl software-properties-common",
            "osctl ct exec #{ct} bash -c \"curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add -\"",
            "osctl ct exec #{ct} add-apt-repository \"deb [arch=amd64] https://download.docker.com/linux/ubuntu noble stable\"",
            "osctl ct exec #{ct} apt-get update -y",
            "osctl ct exec #{ct} apt-get -y install docker-ce",
          )

          configure_docker_registry_mirrors(ct)
          machine.succeeds("osctl ct exec #{ct} systemctl restart docker")
        '';
      }
    ];
  in
  {
    name = "docker";

    description = ''
      Test Docker in containers
    '';

    tags = [ "ci" ];

    machine = import ../machines/vpsadminos/tank.nix pkgs;

    testScripts = builtins.listToAttrs (
      map (test: {
        name = test.name;
        value = {
          description = ''
            Test Docker on ${test.distribution} ${test.version}
          '';
          script = common + ''
            ct = get_container_id('docker')

            begin
              ensure_machine
              create_docker_container(ct, '${test.distribution}', '${test.version}')
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
