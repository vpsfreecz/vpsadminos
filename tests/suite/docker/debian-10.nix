import ./base.nix {
  distribution = "debian";
  version = "10";
  setupScript = ''
    machine.all_succeed(
      "osctl ct exec docker apt-update -y",
      "osctl ct exec docker apt-get -y install apt-transport-https ca-certificates curl gnupg-agent software-properties-common",
      "osctl ct exec docker bash -c \"curl -fsSL https://download.docker.com/linux/debian/gpg | apt-key add -\"",
      "osctl ct exec docker add-apt-repository \"deb [arch=amd64] https://download.docker.com/linux/debian buster stable\"",
      "osctl ct exec docker apt-get update -y",
      "osctl ct exec docker apt-get -y install docker-ce",
    )
  '';
}
