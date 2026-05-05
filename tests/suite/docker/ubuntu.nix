import ./base.nix {
  distribution = "ubuntu";
  tests = [
    {
      version = "20.04";
      setup = ''
        machine.all_succeed(
          "osctl ct exec #{ct} apt-get update -y",
          "osctl ct exec #{ct} apt-get -y install apt-transport-https ca-certificates curl software-properties-common",
          "osctl ct exec #{ct} bash -c \"curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add -\"",
          "osctl ct exec #{ct} add-apt-repository \"deb [arch=amd64] https://download.docker.com/linux/ubuntu focal stable\"",
          "osctl ct exec #{ct} apt-get update -y",
          "osctl ct exec #{ct} apt-get -y install docker-ce",
        )

        configure_docker_registry_mirrors(ct)
        machine.succeeds("osctl ct exec #{ct} systemctl restart docker")
      '';
    }
    {
      version = "22.04";
      setup = ''
        machine.all_succeed(
          "osctl ct exec #{ct} apt-get update -y",
          "osctl ct exec #{ct} apt-get -y install apt-transport-https ca-certificates curl software-properties-common",
          "osctl ct exec #{ct} bash -c \"curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add -\"",
          "osctl ct exec #{ct} add-apt-repository \"deb [arch=amd64] https://download.docker.com/linux/ubuntu focal stable\"",
          "osctl ct exec #{ct} apt-get update -y",
          "osctl ct exec #{ct} apt-get -y install docker-ce",
        )

        configure_docker_registry_mirrors(ct)
        machine.succeeds("osctl ct exec #{ct} systemctl restart docker")
      '';
    }
    {
      version = "24.04";
      setup = ''
        machine.all_succeed(
          "osctl ct exec #{ct} apt-get update -y",
          "osctl ct exec #{ct} apt-get -y install apt-transport-https ca-certificates curl software-properties-common",
          "osctl ct exec #{ct} bash -c \"curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add -\"",
          "osctl ct exec #{ct} add-apt-repository \"deb [arch=amd64] https://download.docker.com/linux/ubuntu noble stable\"",
          "osctl ct exec #{ct} apt-get update -y",
          "osctl ct exec #{ct} apt-get -y install docker-ce",
        )

        configure_docker_registry_mirrors(ct)
        machine.succeeds("osctl ct exec #{ct} systemctl restart docker")
      '';
    }
  ];
}
