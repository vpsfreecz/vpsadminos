import ./base.nix {
  distribution = "debian";
  tests = [
    {
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
}
