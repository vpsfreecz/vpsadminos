# This file provides compatibility for NixOS to run in a container on vpsAdminOS
# hosts.
#
# If you're experiencing issues, try updating this file to the latest version
# from vpsAdminOS repository:
#
#   https://github.com/vpsfreecz/vpsadminos/blob/staging/os/lib/nixos-container/stable/vpsadminos.nix

{
  config,
  lib,
  options,
  pkgs,
  utils,
  ...
}:
let
  inherit (lib)
    mkDefault
    mkOverride
    mkForce
    ;

  legacyUsers = !config.systemd.sysusers.enable && !config.services.userborn.enable;
  bootSpecialFileSystemOpts = options.boot.specialFileSystems.type.getSubOptions { };
  bootNeededFileSystems = lib.pipe config.fileSystems [
    (lib.filterAttrs (_: v: utils.fsNeededForBoot v))
    (builtins.mapAttrs (
      path: v:
      lib.warnIf (v.autoFormat || v.autoResize || v.encrypted.enable || v.overlay.workdir != null)
        "fileSystems.${path} has options set that are not supported by boot.specialFileSystems."
        (lib.intersectAttrs bootSpecialFileSystemOpts v)
    ))
  ];
  bootNeededBindMounts = lib.filter (
    mount:
    (mount.enable or true)
    && mount ? where
    && mount ? what
    && (mount.type or null) == "none"
    && builtins.elem "bind" (lib.splitString "," (mount.options or ""))
    && builtins.elem mount.where utils.pathsNeededForBoot
  ) config.systemd.mounts;
  coversPath = parent: path: parent == path || lib.hasPrefix "${lib.removeSuffix "/" parent}/" path;
  earlyMounts = builtins.attrValues config.boot.specialFileSystems;
  directoryBind =
    mount:
    lib.any (option: builtins.elem option mount.options) [
      "bind"
      "rbind"
    ];
  persistedStateMounts = lib.filter (
    mount:
    mount.mountPoint != "/"
    && lib.any (coversPath mount.mountPoint) [
      "/var/lib/nixos"
      "/var/log"
    ]
  ) earlyMounts;
  selectedStateMount =
    mount: lib.any (selected: selected.mountPoint == mount.mountPoint) persistedStateMounts;
  # Membership only: the upstream earlyMountScript still orders every mount.
  requiredStateMounts = map (entry: entry.mount) (
    lib.genericClosure {
      startSet = map (mount: {
        key = mount.mountPoint;
        inherit mount;
      }) persistedStateMounts;
      operator =
        entry:
        map (mount: {
          key = mount.mountPoint;
          inherit mount;
        }) (lib.filter (mount: utils.fsBefore mount entry.mount) earlyMounts);
    }
  );
  backingMounts =
    source:
    lib.concatMap (mount: [
      (if directoryBind mount then "bind" else "filesystem")
      (toString mount.device)
      mount.mountPoint
    ]) (lib.filter (mount: coversPath mount.mountPoint source) earlyMounts);

  persistedSpecialfs = ''
    # Only missing directories receive root/0755 defaults; keep existing metadata.
    vpsadminosPrepareStateDirectory() {
      local path="$1" parent
      if [ -e "$path" ] || [ -L "$path" ]; then
        [ -d "$path" ] || return 1
        return 0
      fi
      parent=$(dirname -- "$path") || return 1
      vpsadminosPrepareStateDirectory "$parent" || return 1
      mkdir -m 0755 -- "$path" || return 1
      # Clear inherited group and special bits on this new directory only.
      chown 0:0 -- "$path" || return 1
      chmod 00755 -- "$path" || return 1
    }
    vpsadminosMountRequired() {
      local source="$1" target="$2" options="$3" fsType="$4" selected="$5" directoryBind="$6"
      local backingType backingSource backing mounted=false mountStatus
      shift 6
      # Exact declared early mountpoints must be available, including / when
      # configured. Undeclared host binds retain their existing host contract.
      while [ "$#" -gt 0 ]; do
        backingType="$1" backingSource="$2" backing="$3"
        shift 3
        mountpoint -q -- "$backing" || return 1
        if [ "$backingType" = bind ]; then
          [ -d "$backingSource" ] && [ -d "$backing" ] && [ "$backingSource" -ef "$backing" ] || return 1
        fi
      done
      if [ -e "$target" ] || [ -L "$target" ]; then
        [ -d "$target" ] || return 1
        if mountpoint -q -- "$target"; then
          mounted=true
          if "$directoryBind" && ! { [ -d "$source" ] && [ "$source" -ef "$target" ]; }; then
            printf 'vpsAdminOS: state destination has a different mounted source: %s\n' "$target" >&2
            return 1
          fi
        else
          mountStatus=$?
          # util-linux returns 32 for a directory that is not a mountpoint.
          [ "$mountStatus" -eq 32 ] || return 1
        fi
      fi
      if "$directoryBind"; then
        if "$selected"; then
          vpsadminosPrepareStateDirectory "$source" || return 1
        else
          # A prerequisite bind must not hide unavailable storage with mkdir.
          [ -d "$source" ] || return 1
        fi
      fi
      if "$mounted"; then
        mount -t "$fsType" -o "remount,$options" "$source" "$target" || return 1
      else
        vpsadminosPrepareStateDirectory "$target" || return 1
        mount -t "$fsType" -o "$options" "$source" "$target" || return 1
      fi
      mountpoint -q -- "$target" || return 1
      if "$directoryBind"; then
        [ -d "$source" ] && [ "$source" -ef "$target" ] || return 1
      fi
    }
    specialMount() {
      local device="$1" mountPoint="$2" options="$3" fsType="$4"
      ${lib.concatMapStringsSep "\n" (mount: ''
        if [ "$device" = ${lib.escapeShellArg (toString mount.device)} ] && [ "$mountPoint" = ${lib.escapeShellArg mount.mountPoint} ] && [ "$options" = ${lib.escapeShellArg (lib.concatStringsSep "," mount.options)} ] && [ "$fsType" = ${lib.escapeShellArg mount.fsType} ]; then
          # Exit the parent activation shell: its ERR trap alone permits users.
          if ! vpsadminosMountRequired "$device" "$mountPoint" "$options" "$fsType" ${
            if selectedStateMount mount then "true" else "false"
          } ${if directoryBind mount then "true" else "false"} ${
            lib.escapeShellArgs (
              if directoryBind mount && selectedStateMount mount then
                backingMounts (toString mount.device)
              else
                [ ]
            )
          }; then
            printf 'vpsAdminOS: persisted state unavailable; refusing user allocation\n' >&2
            exit 1
          fi
          return 0
        fi
      '') requiredStateMounts}
      # Keep this fallback aligned with upstream activation-script.nix specialfs.
      # The global earlyMountScript remains responsible for all mount ordering.
      if mountpoint -q "$mountPoint"; then
        local options="remount,$options"
      else
        mkdir -p "$mountPoint"
        chmod 0755 "$mountPoint"
      fi
      mount -t "$fsType" -o "$options" "$device" "$mountPoint"
    }
    source ${config.system.build.earlyMountScript}
  '';

  nameservers = [
    "1.1.1.1"
    "2606:4700:4700::1111"
  ];
in
{
  networking.nameservers = mkDefault nameservers;
  services.resolved.settings.Resolve = mkDefault { FallbackDNS = nameservers; };
  networking.dhcpcd.extraConfig = "noipv4ll";

  systemd.services.systemd-oomd.enable = false;
  systemd.sockets."systemd-journald-audit".enable = false;
  systemd.mounts = [
    {
      where = "/sys/kernel/debug";
      enable = false;
    }
  ];
  systemd.services.rpc-gssd.enable = false;

  # Needed for systemd since v258, see issue #39036
  systemd.services.console-getty.serviceConfig = {
    StandardInput = "null";
    StandardOutput = "null";
  };

  # Due to our restrictions in /sys, the default systemd-udev-trigger fails
  # on accessing PCI devices, etc. Override it to match only network devices.
  # In addition, boot.isContainer prevents systemd-udev-trigger.service from
  # being enabled at all, so add it explicitly.
  systemd.additionalUpstreamSystemUnits = [
    "systemd-udev-trigger.service"
  ];
  systemd.services.systemd-udev-trigger.serviceConfig.ExecStart = [
    ""
    "-udevadm trigger --subsystem-match=net --action=add"
  ];

  boot.isContainer = true;
  boot.enableContainers = mkDefault true;
  boot.loader.initScript.enable = true;
  boot.systemdExecutable = mkDefault "/run/current-system/systemd/lib/systemd/systemd systemd.unified_cgroup_hierarchy=0";
  console.enable = true;

  # Containers have no initrd. Keep the complete promotion and global mount
  # order, including state binds: LXC's proc mount can skip stage 2's mounts.
  boot.specialFileSystems =
    let
      bootNeededBinds = builtins.listToAttrs (
        map (mount: {
          name = mount.where;
          value = lib.intersectAttrs bootSpecialFileSystemOpts {
            device = mount.what;
            fsType = mount.type or "none";
            options = lib.splitString "," (mount.options or "");
          };
        }) bootNeededBindMounts
      );
    in
    bootNeededFileSystems
    // bootNeededBinds
    // {
      "/run/keys".fsType = mkForce "tmpfs";
    };

  system.activationScripts = lib.mkIf (legacyUsers && persistedStateMounts != [ ]) {
    specialfs = mkOverride 90 {
      text = persistedSpecialfs;
      supportsDryActivation = false;
    };
    users.deps = [ "specialfs" ];
  };

  # Overrides for <nixpkgs/nixos/modules/virtualisation/container-config.nix>
  documentation.enable = mkOverride 500 true;
  documentation.nixos.enable = mkOverride 500 true;
  networking.useHostResolvConf = mkOverride 500 false;
  services.openssh.startWhenNeeded = mkOverride 500 false;

  # Bring up the network, /ifcfg.{add,del} are supplied by the vpsAdminOS host
  systemd.services.networking-setup = {
    description = "Load network configuration provided by the vpsAdminOS host";
    before = [ "network.target" ];
    wantedBy = [ "network.target" ];
    after = [ "network-pre.target" ];
    path = [ pkgs.iproute2 ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${pkgs.bash}/bin/bash /ifcfg.add";
      ExecStop = "${pkgs.bash}/bin/bash /ifcfg.del";
    };
    unitConfig.ConditionPathExists = "/ifcfg.add";
    restartIfChanged = false;
  };
}
