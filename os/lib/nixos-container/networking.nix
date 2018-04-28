{ config, pkgs, lib, ...}: {

  networking = {
      # hostName = "nixos";
      useHostResolvConf = lib.mkDefault true;
  };

  systemd.services.networking-setup =
    { description = "Load network configuration provided by host";

      before = [ "network.target" ];
      wantedBy = [ "network.target" ];
      after = [ "network-pre.target" ];
      path = [ pkgs.iproute ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${pkgs.bash}/bin/bash /ifcfg.add";
        ExecStop = "${pkgs.bash}/bin/bash /ifcfg.del";
      };
      unitConfig.ConditionPathExists = "/ifcfg.add";
    };
}
