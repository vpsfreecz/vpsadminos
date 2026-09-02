import ./base.nix {
  distribution = "alpine";
  tests = [
    {
      version = "latest";
      setup = ''
        container_apk(machine, ct, 'update', name: "Update APK indexes in #{ct}")
        container_apk(machine, ct, 'add', 'docker', name: "Install Docker in #{ct}")

        configure_docker_registry_mirrors(ct)
        machine.succeeds("osctl ct exec #{ct} service docker start")
      '';
    }
  ];
}
