import ./lxd-base.nix {
  distribution = "fedora";
  version = "latest";
  setupScript = ''
    machine.all_succeed(
      "osctl ct exec snapct dnf -y update",
      "osctl ct exec snapct dnf -y install screen squashfuse snapd",
      "osctl ct exec snapct ln -s /var/lib/snapd/snap /snap",
    )
  '';
}
