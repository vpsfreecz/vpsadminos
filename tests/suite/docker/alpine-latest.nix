import ./base.nix {
  distribution = "alpine";
  version = "latest";
  setupScript = ''
    machine.all_succeed(
      "osctl ct exec docker apk update",
      "osctl ct exec docker apk add docker",
      "osctl ct exec docker service docker start",
    )
  '';
}
