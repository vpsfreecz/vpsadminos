import ./base.nix {
  distribution = "almalinux";
  tests = [
    {
      version = "8";
      setup = ''
        machine.all_succeed(
          "osctl ct exec #{ct} yum update -y",
          "osctl ct exec #{ct} yum install -y yum-utils",
          "osctl ct exec #{ct} yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo",
          "osctl ct exec #{ct} yum install -y docker-ce docker-ce-cli containerd.io",
        )

        configure_docker_registry_mirrors(ct)
        machine.succeeds("osctl ct exec #{ct} systemctl start docker")
      '';
    }
    {
      version = "9";
      setup = ''
        machine.all_succeed(
          "osctl ct exec #{ct} yum update -y",
          "osctl ct exec #{ct} yum install -y yum-utils",
          "osctl ct exec #{ct} yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo",
          "osctl ct exec #{ct} yum install -y docker-ce docker-ce-cli containerd.io",
        )

        configure_docker_registry_mirrors(ct)
        machine.succeeds("osctl ct exec #{ct} systemctl start docker")
      '';
    }
    {
      version = "10";
      setup = ''
        machine.all_succeed(
          "osctl ct exec #{ct} yum update -y",
          "osctl ct exec #{ct} yum install -y yum-utils",
          "osctl ct exec #{ct} yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo",
          "osctl ct exec #{ct} yum install -y docker-ce docker-ce-cli containerd.io",
        )

        configure_docker_registry_mirrors(ct)
        machine.succeeds("osctl ct exec #{ct} systemctl start docker")
      '';
    }
  ];
}
