import ./base.nix {
  distribution = "fedora";
  version = "latest";
  setupScript = ''
    machine.all_succeed(
      "osctl ct exec incusct dnf -y update",
      "osctl ct exec incusct dnf -y install incus",
    )
  '';
}
