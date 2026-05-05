import ./base.nix {
  distribution = "arch";
  tests = [
    {
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
  ];
}
