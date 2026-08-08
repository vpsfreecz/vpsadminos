import ./base.nix {
  distribution = "fedora";
  tests = [
    {
      version = "latest";
      setup = ''
        machine.all_succeed(
          "osctl ct exec #{ct} dnf -y install podman",
        )

        configure_podman_registry_mirrors(ct)
      '';
    }
  ];
}
