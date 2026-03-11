import ./base.nix {
  distribution = "alpine";
  version = "latest";
  setupScript = ''
    machine.all_succeed(
      "osctl ct exec docker apk update",
      "osctl ct exec docker apk add docker",
    )

    configure_docker_registry_mirrors('docker')
    machine.succeeds("osctl ct exec docker service docker start")
  '';
}
