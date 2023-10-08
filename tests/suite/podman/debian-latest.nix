import ./base.nix {
  distribution = "debian";
  version = "latest";
  setupScript = ''
    machine.all_succeed(
      "osctl ct exec podmanct apt-get -y update",
      "osctl ct exec podmanct apt-get -y install podman",
    )
  '';
}
