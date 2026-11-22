{
  lib,
  modulesPath,
  pkgs,
  ...
}:
{
  imports = [
    "${modulesPath}/virtualisation/container-config.nix"
    # The image build must use the same guest support as the generated flake.
    (./. + "/vpsadminos-${lib.trivial.release}.nix")
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
