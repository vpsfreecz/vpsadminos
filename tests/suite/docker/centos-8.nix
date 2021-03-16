import ./base.nix {
  distribution = "centos";
  version = "8";
  setupScript = ''
    machine.all_succeed(
      "osctl ct exec docker yum update -y",
      "osctl ct exec docker yum install -y yum-utils",
      "osctl ct exec docker yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo",
      "osctl ct exec docker yum install -y docker-ce docker-ce-cli containerd.io",
      "osctl ct exec docker systemctl start docker",
    )
  '';
}
