{ config, lib, oslib, pkgs, ... }:
with lib;
let
  cfg = config.networking.firewall;
  systemdService = config.systemd.services.firewall;
  cmd = opt: oslib.systemd.extractExecCommand opt;
  systemPath = concatMapStringsSep ":" (pkg: "${pkg}/bin") systemdService.path;
in
{
  ###### interface

  imports = [
    <nixpkgs/nixos/modules/services/networking/firewall.nix>
  ];

  ###### implementation

  config = mkIf cfg.enable {
    runit.services.firewall = {
      run = ''
        ensureServiceStarted eudev-trigger
        export PATH="${systemPath}:$PATH"
        ${cmd systemdService.serviceConfig.ExecStart} || exit 1
        exec sleep inf
      '';

      control.usr1 = ''
        export PATH="${systemPath}:$PATH"
        exec ${cmd systemdService.serviceConfig.ExecReload}
      '';

      control.down = ''
        export PATH="${systemPath}:$PATH"
        ${cmd systemdService.serviceConfig.ExecStop}
        exit 1 # always fail so that runsv kills the infinite sleep run above
      '';

      onChange = "reload";
      reloadMethod = "1";
    };
  };
}
