pkgs: {
  spin = "nixos";

  config = {
    networking.hostName = "nixos";
    virtualisation.memorySize = 2048;
    virtualisation.cores = 2;
  };
}
