import ./base.nix {
  distribution = "ubuntu";
  tests = [
    {
      version = "20.04";
      setup = ''
        container_apt_get(machine, ct, 'update', '-y', name: "APT metadata refresh in #{ct}")
        container_apt_get(
          machine,
          ct,
          'install',
          '-y',
          'apt-transport-https',
          'ca-certificates',
          'curl',
          'software-properties-common',
          name: "APT prerequisite installation in #{ct}",
        )

        machine.all_succeed(
          "osctl ct exec #{ct} bash -c \"curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add -\"",
          "osctl ct exec #{ct} add-apt-repository \"deb [arch=amd64] https://download.docker.com/linux/ubuntu focal stable\"",
        )

        container_apt_get(machine, ct, 'update', '-y', name: "Docker APT metadata refresh in #{ct}")
        container_apt_get(
          machine,
          ct,
          'install',
          '-y',
          'docker-ce',
          name: "Docker APT package installation in #{ct}",
        )

        configure_docker_registry_mirrors(ct)
        machine.succeeds("osctl ct exec #{ct} systemctl restart docker")
      '';
    }
    {
      version = "22.04";
      setup = ''
        container_apt_get(machine, ct, 'update', '-y', name: "APT metadata refresh in #{ct}")
        container_apt_get(
          machine,
          ct,
          'install',
          '-y',
          'apt-transport-https',
          'ca-certificates',
          'curl',
          'software-properties-common',
          name: "APT prerequisite installation in #{ct}",
        )

        machine.all_succeed(
          "osctl ct exec #{ct} bash -c \"curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add -\"",
          "osctl ct exec #{ct} add-apt-repository \"deb [arch=amd64] https://download.docker.com/linux/ubuntu focal stable\"",
        )

        container_apt_get(machine, ct, 'update', '-y', name: "Docker APT metadata refresh in #{ct}")
        container_apt_get(
          machine,
          ct,
          'install',
          '-y',
          'docker-ce',
          name: "Docker APT package installation in #{ct}",
        )

        configure_docker_registry_mirrors(ct)
        machine.succeeds("osctl ct exec #{ct} systemctl restart docker")
      '';
    }
    {
      version = "24.04";
      setup = ''
        container_apt_get(machine, ct, 'update', '-y', name: "APT metadata refresh in #{ct}")
        container_apt_get(
          machine,
          ct,
          'install',
          '-y',
          'apt-transport-https',
          'ca-certificates',
          'curl',
          'software-properties-common',
          name: "APT prerequisite installation in #{ct}",
        )

        machine.all_succeed(
          "osctl ct exec #{ct} bash -c \"curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add -\"",
          "osctl ct exec #{ct} add-apt-repository \"deb [arch=amd64] https://download.docker.com/linux/ubuntu noble stable\"",
        )

        container_apt_get(machine, ct, 'update', '-y', name: "Docker APT metadata refresh in #{ct}")
        container_apt_get(
          machine,
          ct,
          'install',
          '-y',
          'docker-ce',
          name: "Docker APT package installation in #{ct}",
        )

        configure_docker_registry_mirrors(ct)
        machine.succeeds("osctl ct exec #{ct} systemctl restart docker")
      '';
    }
  ];
}
