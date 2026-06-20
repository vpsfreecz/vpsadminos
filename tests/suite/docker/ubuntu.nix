import ./base.nix {
  distribution = "ubuntu";
  tests = [
    {
      version = "20.04";
      setup = ''
        machine.all_succeed(
          "osctl ct exec #{ct} apt-get update -y",
          "osctl ct exec #{ct} apt-get -y install ca-certificates curl",
          "osctl ct exec #{ct} install -m 0755 -d /etc/apt/keyrings",
          "osctl ct exec #{ct} curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc",
          "osctl ct exec #{ct} chmod a+r /etc/apt/keyrings/docker.asc",
          "osctl ct exec #{ct} bash -c 'echo \"deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable\" > /etc/apt/sources.list.d/docker.list'",
          "osctl ct exec #{ct} apt-get update -y",
          "osctl ct exec #{ct} apt-get -y install docker-ce docker-ce-cli containerd.io",
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
          "osctl ct exec #{ct} apt-get -y install ca-certificates curl",
          "osctl ct exec #{ct} install -m 0755 -d /etc/apt/keyrings",
          "osctl ct exec #{ct} curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc",
          "osctl ct exec #{ct} chmod a+r /etc/apt/keyrings/docker.asc",
          "osctl ct exec #{ct} bash -c 'echo \"deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable\" > /etc/apt/sources.list.d/docker.list'",
          "osctl ct exec #{ct} apt-get update -y",
          "osctl ct exec #{ct} apt-get -y install docker-ce docker-ce-cli containerd.io",
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
          "osctl ct exec #{ct} apt-get -y install ca-certificates curl",
          "osctl ct exec #{ct} install -m 0755 -d /etc/apt/keyrings",
          "osctl ct exec #{ct} curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc",
          "osctl ct exec #{ct} chmod a+r /etc/apt/keyrings/docker.asc",
          "osctl ct exec #{ct} bash -c 'echo \"deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable\" > /etc/apt/sources.list.d/docker.list'",
          "osctl ct exec #{ct} apt-get update -y",
          "osctl ct exec #{ct} apt-get -y install docker-ce docker-ce-cli containerd.io",
        )

        configure_docker_registry_mirrors(ct)
        machine.succeeds("osctl ct exec #{ct} systemctl restart docker")
      '';
    }
  ];
}
