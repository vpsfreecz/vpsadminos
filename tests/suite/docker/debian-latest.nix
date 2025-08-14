import ./base.nix {
  distribution = "debian";
  version = "latest";
  setupScript = ''
    machine.all_succeed(
      "osctl ct exec docker apt-get update -y",
      "osctl ct exec docker apt-get -y install ca-certificates curl",
      "osctl ct exec docker curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc",
      "osctl ct exec docker chmod a+r /etc/apt/keyrings/docker.asc",
      "osctl ct exec docker bash -c 'echo \"deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $(. /etc/os-release && echo $VERSION_CODENAME) stable\" > /etc/apt/sources.list.d/docker.list'",
      "osctl ct exec docker apt-get update -y",
      "osctl ct exec docker apt-get -y install docker-ce docker-ce-cli containerd.io",
    )
  '';
}
