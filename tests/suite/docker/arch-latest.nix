import ./base.nix {
  distribution = "arch";
  version = "latest";
  setupScript = ''
    machine.all_succeed(
      "osctl ct exec docker pacman -Syu --noconfirm docker",
      "osctl ct exec docker systemctl enable docker.service",
      "osctl ct exec docker systemctl start docker.service",
    )
  '';
}
