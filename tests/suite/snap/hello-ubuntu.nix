import ./hello-base.nix {
  distribution = "ubuntu";
  version = "latest";
  setupScript = ''
    machine.all_succeed(
      "osctl ct exec snapct apt-get update -y",
      "osctl ct exec snapct apt-get -y install snapd",
    )
  '';
}
