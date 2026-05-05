import ./base.nix {
  distribution = "alpine";
  tests = [
    {
      version = "latest";
      setup = ''
        machine.all_succeed(
          "osctl ct exec #{ct} apk update",
          "osctl ct exec #{ct} apk add docker",
        )

        configure_docker_registry_mirrors(ct)
        machine.succeeds("osctl ct exec #{ct} service docker start")
      '';
    }
  ];
}
