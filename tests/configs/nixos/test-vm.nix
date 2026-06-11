{ lib, ... }:
{
  virtualisation.memorySize = lib.mkDefault 2048;
  virtualisation.cores = lib.mkDefault 2;
  virtualisation.fileSystems = lib.mkForce { };
  virtualisation.mountHostNixStore = lib.mkForce false;
  virtualisation.sharedDirectories = lib.mkForce { };
}
