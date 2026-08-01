import ./base.nix {
  distribution = "arch";
  tests = [
    {
      version = "latest";
      setup = ''
        machine.succeeds_with_retries(
          "osctl ct exec #{ct} pacman -Syu --noconfirm docker",
          attempts: 3,
          retry_delay: 15,
          timeout: 900,
        )
        machine.succeeds("osctl ct exec #{ct} systemctl enable docker.service")

        configure_docker_registry_mirrors(ct)
        machine.succeeds("osctl ct exec #{ct} systemctl start docker.service")
      '';
    }
  ];
}
