import ./base.nix {
  distribution = "debian";
  version = "latest";
  setupScript = ''
    machine.all_succeed(
      "osctl ct exec incusct apt-get update -y",
      "osctl ct exec incusct apt-get -y install incus",
    )
  '';
}
