{ config, lib, ... }:
{
  config = {
    system.activationScripts.wrappers =
      lib.stringAfter [ "specialfs" "users" ] config.systemd.services.suid-sgid-wrappers.script;
  };
}
