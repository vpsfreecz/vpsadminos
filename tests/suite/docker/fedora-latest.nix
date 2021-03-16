import ./base.nix {
  distribution = "fedora";
  version = "latest";
  setupScript = ''
    machine.all_succeed(
      "osctl ct exec docker dnf -y update",
      "osctl ct exec docker dnf -y install dnf-plugins-core",
      "osctl ct exec docker dnf config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo",
      "osctl ct exec docker dnf -y install docker-ce docker-ce-cli containerd.io",
      "osctl ct exec docker systemctl start docker",
    )
  '';
}
