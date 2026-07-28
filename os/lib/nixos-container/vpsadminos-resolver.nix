{
  config,
  lib,
  pkgs,
  ...
}:
let
  resolvedEnabled = config.services.resolved.enable;
  backend = if resolvedEnabled then "resolved" else "openresolv";
  source = builtins.readFile ./vpsadminos-dns-update.py;
  renderedSource =
    lib.replaceStrings
      [
        "@python@"
        "@backend@"
        "@resolvconf@"
        "@systemctl@"
      ]
      [
        "${pkgs.python3}/bin/python3"
        backend
        "${pkgs.openresolv}/sbin/resolvconf"
        "${pkgs.systemd}/bin/systemctl"
      ]
      source;
  dnsUpdate = pkgs.writeTextFile {
    name = "vpsadminos-dns-update";
    destination = "/bin/vpsadminos-dns-update";
    executable = true;
    text = renderedSource;
  };
in
{
  environment.systemPackages = [ dnsUpdate ];

  systemd.services.vpsadminos-dns-update = {
    description = "Apply DNS resolvers managed by vpsAdminOS";
    wantedBy = [ "network.target" ];
    before = [ "network.target" ];
    after = [ "local-fs.target" ] ++ lib.optional resolvedEnabled "systemd-resolved.service";
    requires = lib.optional resolvedEnabled "systemd-resolved.service";
    unitConfig.ConditionPathExists = "/run/vpsadminos/resolv.conf";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${dnsUpdate}/bin/vpsadminos-dns-update";
      StandardInput = "file:/run/vpsadminos/resolv.conf";
    };
    restartIfChanged = true;
  };
}
