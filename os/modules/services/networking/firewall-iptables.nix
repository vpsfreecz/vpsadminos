{
  config,
  lib,
  oslib,
  pkgs,
  ...
}:
with lib;
let
  cfg = config.networking.firewall;
  systemdService = config.systemd.services.firewall;
  cmd = opt: oslib.systemd.extractExecCommand opt;
in
{
  # Based on <nixpkgs/nixos/modules/services/networking/firewall-iptables.nix>

  config = mkIf (cfg.enable && config.networking.nftables.enable == false) {
    runit.services.firewall = {
      path = systemdService.path;

      run = ''
        ensureServiceStarted eudev-trigger
        ${cmd systemdService.serviceConfig.ExecStart} || exit 1
        exec sleep inf
      '';

      control.usr1 = ''
        exec ${cmd systemdService.serviceConfig.ExecReload}
      '';

      control.down = ''
        ${cmd systemdService.serviceConfig.ExecStop}
        exit 1 # always fail so that runsv kills the infinite sleep run above
      '';

      onChange = "reload";
      reloadMethod = "1";
    };
  };
}
