import ./base.nix {
  distribution = "arch";
  version = "latest";
  setupScript = ''
    machine.all_succeed(
      "osctl ct exec docker pacman -Syu --noconfirm docker",
      "osctl ct exec docker systemctl enable docker.service",
    )

    configure_docker_registry_mirrors('docker')
    machine.succeeds("osctl ct exec docker systemctl start docker.service")
  '';
}
