import ./base.nix {
  distribution = "fedora";
  tests = [
    {
      version = "latest";
      setup = ''
        machine.all_succeed(
          "osctl ct exec #{ct} dnf -y install dnf-plugins-core",
          "osctl ct exec #{ct} dnf-3 config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo",
          "osctl ct exec #{ct} dnf -y install docker-ce docker-ce-cli containerd.io",
        )

        configure_docker_registry_mirrors(ct)
        machine.succeeds("osctl ct exec #{ct} systemctl start docker")
      '';
    }
  ];
}
