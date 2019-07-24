{ config, lib, pkgs, utils, ... }:
with utils;
with lib;

let
  cfg = config.services.openssh;
in
{
  ###### interface

  options = {};

  ###### implementation

  config = mkMerge [
    (mkIf (config.services.openssh.enable) {
      services.openssh.extraConfig = mkOrder 100 ''
        PidFile /run/sshd.pid

        Match User osctl-ct-receive
          PasswordAuthentication no
          AuthorizedKeysFile /run/osctl/send-receive/authorized_keys
      '';

      runit.services.sshd = {
        run = ''
          # Ensure SSH host keys
          mkdir -m 0755 -p /etc/ssh
          ${flip concatMapStrings cfg.hostKeys (k: ''
            if ! [ -f "${k.path}" ]; then
                ssh-keygen \
                  -t "${k.type}" \
                  ${if k ? bits then "-b ${toString k.bits}" else ""} \
                  ${if k ? rounds then "-a ${toString k.rounds}" else ""} \
                  ${if k ? comment then "-C '${k.comment}'" else ""} \
                  ${if k ? openSSHFormat && k.openSSHFormat then "-o" else ""} \
                  -f "${k.path}" \
                  -N ""
            fi
          '')}

          exec ${pkgs.openssh}/bin/sshd -D -f /etc/ssh/sshd_config

          # This is here to ensure the service file is changed together with
          # the config file, since only changed services are restarted when
          # switching configuration.
          # Config: ${config.environment.etc."ssh/sshd_config".source}
        '';
        killMode = "process";
        runlevels = [ "rescue" "default" ];
      };
    })
  ];
}
