{ config, lib, pkgs, utils, ... }:
with utils;
with lib;

let
  sshd_config = pkgs.writeText "sshd_config" ''
    HostKey /etc/ssh/ssh_host_rsa_key
    HostKey /etc/ssh/ssh_host_ed25519_key
    UsePAM yes
    Port 22
    PidFile /run/sshd.pid
    Protocol 2
    PermitRootLogin yes
    PasswordAuthentication yes
    ChallengeResponseAuthentication no

    Match User root
      AuthorizedKeysFile /etc/ssh/authorized_keys.d/%u

    Match User migration
      PasswordAuthentication no
      AuthorizedKeysFile /run/osctl/migration/authorized_keys
  '';
in
{
  ###### interface

  options = {
  };

  ###### implementation

  config = mkMerge [
    (mkIf (config.services.openssh.enable) {
      runit.services.sshd = {
        run = ''
          exec ${pkgs.openssh}/bin/sshd -D -f ${sshd_config}
        '';
        killMode = "process";
      };

      environment.etc = {
        "ssh/ssh_host_rsa_key.pub".source = ../../../ssh/ssh_host_rsa_key.pub;
        "ssh/ssh_host_rsa_key" = { mode = "0600"; source = ../../../ssh/ssh_host_rsa_key; };
        "ssh/ssh_host_ed25519_key.pub".source = ../../../ssh/ssh_host_ed25519_key.pub;
        "ssh/ssh_host_ed25519_key" = { mode = "0600"; source = ../../../ssh/ssh_host_ed25519_key; };
      };
    })
  ];
}
