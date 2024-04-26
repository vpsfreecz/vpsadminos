{ config, lib, pkgs, utils, ... }:
# TODO: remove this module when we no longer need it for backward compatibility
let
  inherit (lib) mkRenamedOptionModule;

  cfg = config.osctl.exporter;
in {
  imports = [
    (lib.mkRenamedOptionModule [ "osctl" "exporter" "enable" ] [ "services" "prometheus" "exporters" "osctl" "enable" ])
    (lib.mkRenamedOptionModule [ "osctl" "exporter" "listenAddress" ] [ "services" "prometheus" "exporters" "osctl" "listenAddress" ])
    (lib.mkRenamedOptionModule [ "osctl" "exporter" "port" ] [ "services" "prometheus" "exporters" "osctl" "port" ])
  ];
}
