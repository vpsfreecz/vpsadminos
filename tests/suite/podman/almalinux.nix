import ./base.nix {
  distribution = "almalinux";
  tests = [
    {
      version = "10";
      setup = ''
        machine.all_succeed(
          "osctl ct exec #{ct} yum -y update",
          "osctl ct exec #{ct} yum -y install podman",
        )

        configure_podman_registry_mirrors(ct)
      '';
    }
  ];
}
