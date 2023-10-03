import ./hello-base.nix {
  distribution = "fedora";
  version = "latest";
  setupScript = ''
    machine.all_succeed(
      "osctl ct exec snapct dnf -y update",
      "osctl ct exec snapct dnf -y install squashfuse snapd",
    )
  '';
}
