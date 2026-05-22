import ./base.nix {
  distribution = "arch";
  tests = [
    {
      version = "latest";
      setup = ''
        machine.all_succeed(
          "osctl ct exec #{ct} pacman -Syu --noconfirm podman",
        )

        configure_podman_registry_mirrors(ct)
      '';
    }
  ];
}
