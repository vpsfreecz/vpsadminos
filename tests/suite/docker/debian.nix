import ./base.nix {
  distribution = "debian";
  tests = [
    {
      version = "latest";
      setup = ''
        container_apt_get(machine, ct, 'update', '-y', name: "APT metadata refresh in #{ct}")
        container_apt_get(
          machine,
          ct,
          'install',
          '-y',
          'ca-certificates',
          'curl',
          name: "APT prerequisite installation in #{ct}",
        )

        machine.all_succeed(
          "osctl ct exec #{ct} curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc",
          "osctl ct exec #{ct} chmod a+r /etc/apt/keyrings/docker.asc",
          "osctl ct exec #{ct} bash -c 'echo \"deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $(. /etc/os-release && echo $VERSION_CODENAME) stable\" > /etc/apt/sources.list.d/docker.list'",
        )

        container_apt_get(machine, ct, 'update', '-y', name: "Docker APT metadata refresh in #{ct}")
        container_apt_get(
          machine,
          ct,
          'install',
          '-y',
          'docker-ce',
          'docker-ce-cli',
          'containerd.io',
          name: "Docker APT package installation in #{ct}",
        )

        configure_docker_registry_mirrors(ct)
        machine.succeeds("osctl ct exec #{ct} systemctl restart docker")
      '';
    }
  ];
}
