import ./base.nix {
  distribution = "arch";
  tests = [
    {
      version = "latest";
      setup = ''
        machine.succeeds_with_retries(
          "osctl ct exec #{ct} pacman -Syu --noconfirm podman",
          attempts: 3,
          retry_delay: 15,
          timeout: 900,
        )

        configure_podman_registry_mirrors(ct)
      '';
    }
  ];
}
