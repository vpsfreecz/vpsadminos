import ./base.nix {
  distribution = "fedora";
  version = "latest";
  setupScript = ''
    machine.all_succeed(
      "osctl ct exec podmanct dnf -y update",
      "osctl ct exec podmanct dnf -y install podman",
    )
  '';
}
