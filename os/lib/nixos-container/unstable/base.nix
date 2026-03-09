{
  lib,
  modulesPath,
  pkgs,
  ...
}:
{
  imports = [
    "${modulesPath}/virtualisation/container-config.nix"
    ./vpsadminos.nix
  ];

  environment.systemPackages = with pkgs; [ vim ];
  time.timeZone = "Europe/Amsterdam";
  system.stateVersion = lib.trivial.release;

  services.openssh = {
    enable = lib.mkDefault true;
    settings.PermitRootLogin = lib.mkDefault "yes";
    authorizedKeysInHomedir = true;
  };

  systemd.settings.Manager = {
    DefaultTimeoutStartSec = "900s";
  };
}
