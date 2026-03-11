{
  docker = {
    registryMirrors = [
      "https://docker-registry.vpsadminos.org"
    ];
  };

  podman = {
    dockerIoMirrors = [
      "docker-registry.vpsadminos.org"
    ];

    aliases = {
      "hello-world" = "docker.io/library/hello-world";
    };
  };
}
