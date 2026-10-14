# Prepared generations share every definition/input at the old-to-new boundary.
{ system, source }:
let
  fixtures = import ./nixos-container-persistence.nix { inherit system; };
  rawPath =
    release:
    if release == "unstable" then "unstable/vpsadminos.nix" else "stable/vpsadminos-${release}.nix";
  storageFor =
    layout:
    if layout == "root" then
      "/root-storage"
    else if layout == "declared" then
      "/guest-backing"
    else
      "/persistent";
  ancestor =
    layout:
    if layout == "ancestor-var" then
      "/var"
    else if layout == "ancestor-lib" then
      "/var/lib"
    else
      null;
  stateTarget = layout: if ancestor layout == null then "/var/lib/nixos" else ancestor layout;
  exact = layout: ancestor layout == null && layout != "direct";
  definitions =
    release: layout: challenge: failure:
    {
      lib,
      pkgs,
      modulesPath,
      ...
    }:
    let
      storage = storageFor layout;
      ancestorFailure = builtins.elem failure [
        "ancestor-bind"
        "ancestor-conflict"
      ];
      requiredFailure = builtins.elem failure [
        "missing"
        "wrong-backing"
        "required-remount"
      ];
      nonBindFailure = builtins.elem failure [
        "nonbind"
        "nonbind-remount"
        "nonbind-positive"
      ];
    in
    {
      imports = [
        (modulesPath + "/virtualisation/container-config.nix")
        fixtures.impermanenceModule
      ];
      system.stateVersion = "22.11";
      networking.hostName = "persistence-fixture";
      networking.firewall.enable = false;
      systemd.sysusers.enable = false;
      services.userborn.enable = false;
      nix.settings.experimental-features = [
        "nix-command"
        "flakes"
      ];
      environment.systemPackages = [
        pkgs.jq
        pkgs.util-linux
      ];
      users.groups.preservation-test = { };
      users.users.preservation-test = {
        isSystemUser = true;
        group = "preservation-test";
      };
      users.groups.a-preservation-test = lib.mkIf challenge { };
      users.users.a-preservation-test = lib.mkIf challenge {
        isSystemUser = true;
        group = "a-preservation-test";
      };
      environment.persistence.${storage} = {
        hideMounts = true;
        directories =
          lib.optionals (layout != "direct") (
            if ancestor layout != null then
              [
                {
                  directory = ancestor layout;
                  mode = "0710";
                }
              ]
            else
              [
                {
                  directory = "/var/lib/nixos";
                  mode = "0710";
                }
                "/var/log"
              ]
          )
          ++ [
            {
              directory = "/var/lib/preservation-test";
              user = "preservation-test";
              group = "preservation-test";
              mode = "0750";
            }
          ];
        files = [ "/etc/machine-id" ];
      };
      fileSystems = lib.mkMerge [
        (lib.mkIf (layout == "direct") {
          "/var/lib/nixos" = {
            device = "${storage}/var/lib/nixos";
            fsType = "none";
            options = [
              "bind"
              "x-gvfs-hide"
            ];
          };
        })
        (lib.mkIf (layout == "declared") {
          "/guest-backing" = {
            device = "/persistent/backing";
            fsType = "none";
            options = [
              "bind"
              "x-gvfs-hide"
            ];
            neededForBoot = true;
          };
        })
        (lib.mkIf requiredFailure {
          "/required-storage" = {
            device = if failure == "required-remount" then "tmpfs" else "/persistent/required";
            fsType = if failure == "required-remount" then "tmpfs" else "none";
            options =
              if failure == "required-remount" then
                [
                  "remount"
                  "size=invalid"
                ]
              else
                [ "bind" ];
            neededForBoot = true;
          };
        })
        (lib.mkIf nonBindFailure {
          "/var/log" = {
            device = if failure == "nonbind" then "/dev/no-such-persistence-device" else "tmpfs";
            fsType = if failure == "nonbind" then "ext4" else "tmpfs";
            options = if failure == "nonbind-remount" then [ "size=invalid" ] else [ "mode=0755" ];
          };
        })
      ];
      systemd.mounts = lib.mkMerge [
        (lib.mkIf (layout == "dependent") [
          {
            what = "/var/lib/nixos/usr";
            where = "/usr";
            type = "none";
            options = "bind,x-gvfs-hide";
          }
        ])
        (lib.mkIf (failure != null) (
          lib.mkForce (
            if nonBindFailure then
              [ ]
            else
              [
                {
                  what =
                    if requiredFailure then
                      "/required-storage/absent-state"
                    else if ancestorFailure then
                      "/persistent/var/lib"
                    else
                      "/persistent/var/lib/nixos";
                  where = if ancestorFailure then "/var/lib" else "/var/lib/nixos";
                  type = "none";
                  # MS_BIND|MS_REMOUNT requires a live mount; the private namespace
                  # removes the target for deterministic bind-failure cases.
                  options =
                    if
                      builtins.elem failure [
                        "bind"
                        "ancestor-bind"
                      ]
                    then
                      "bind,remount"
                    else
                      "bind,x-gvfs-hide";
                }
              ]
          )
        ))
      ];
    };
  make =
    release: layout: base: challenge: failure:
    let
      c =
        (fixtures.releases.${release}.lib.nixosSystem {
          inherit system;
          modules = [
            (import (base + "/os/lib/nixos-container/${rawPath release}"))
            (definitions release layout challenge failure)
          ];
        }).config;
    in
    assert
      !(
        ancestor layout != null
        || builtins.elem failure [
          "ancestor-bind"
          "ancestor-conflict"
        ]
      )
      || (!(c.boot.specialFileSystems ? "/var/lib/nixos") && !(c.boot.specialFileSystems ? "/var/log"));
    assert
      !(
        layout == "direct"
        || builtins.elem failure [
          "nonbind"
          "nonbind-remount"
          "nonbind-positive"
        ]
      )
      || builtins.all (
        mount:
        !(builtins.elem (mount.where or "") [
          "/var/lib/nixos"
          "/var/log"
        ])
      ) c.systemd.mounts;
    c.system.build.toplevel;
  generations = release: layout: {
    oldInitial = make release layout fixtures.oldSource false null;
    oldChallenge = make release layout fixtures.oldSource true null;
    newInitial = make release layout source false null;
    newChallenge = make release layout source true null;
  };
  variant =
    release: layout: fresh:
    let
      storage = storageFor layout;
      target = stateTarget layout;
    in
    {
      inherit release layout fresh;
      generations = generations release layout;
      mounts = [
        {
          source = "${storage}${target}";
          inherit target;
        }
      ]
      ++ (
        if exact layout then
          [
            {
              source = "${storage}/var/log";
              target = "/var/log";
            }
          ]
        else
          [ ]
      );
      stateBacking = "${storage}/var/lib/nixos";
      sourceDirectory = "${storage}${target}";
      sourcePathInRoot =
        if layout == "root" then
          "${storage}${target}"
        else if layout == "declared" then
          "/backing${target}"
        else
          target;
      # Numeric ownership tests pre-existing source metadata only. Both fixture
      # accounts and every saved allocation remain dynamically assigned.
      sourceMetadata = if fresh || ancestor layout != null then "0:0:755" else "42:43:710";
      absentExactMounts =
        if ancestor layout != null then
          [
            "/var/lib/nixos"
            "/var/log"
          ]
        else if layout == "direct" then
          [ "/var/log" ]
        else
          [ ];
      logBacking = if exact layout || layout == "ancestor-var" then "${storage}/var/log" else null;
    };
in
{
  inherit (fixtures) oldMetadata oldSource;
  expectedRelease = release: fixtures.releases.${release}.lib.trivial.release;
  variants = {
    upgrade-25_11 = variant "25.11" "supplied" false;
    upgrade-26_05 = variant "26.05" "supplied" false;
    upgrade-unstable = variant "unstable" "supplied" false;
    root-backed-26_05 = variant "26.05" "root" false;
    declared-backing-26_05 = variant "26.05" "declared" false;
    dependent-mount-26_05 = variant "26.05" "dependent" false;
    fresh-26_05 = variant "26.05" "supplied" true;
    ancestor-var-26_05 = variant "26.05" "ancestor-var" false;
    ancestor-var-lib-26_05 = variant "26.05" "ancestor-lib" false;
    direct-filesystem-bind-26_05 = variant "26.05" "direct" false;
    fresh-ancestor-26_05 = variant "26.05" "ancestor-lib" true;
    storage-failures-26_05 = (variant "26.05" "failures" false) // {
      failures = builtins.listToAttrs (
        map
          (failure: {
            name = failure;
            value = make "26.05" "supplied" source true failure;
          })
          [
            "missing"
            "bind"
            "conflict"
            "wrong-backing"
            "ancestor-bind"
            "ancestor-conflict"
            "nonbind"
            "nonbind-remount"
            "nonbind-positive"
            "required-remount"
          ]
      );
    };
  };
}
