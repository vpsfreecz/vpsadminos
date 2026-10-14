# Explicit inputs keep this evaluator usable in normal pure flake checks.
{
  source,
  fixtures,
  oldSource,
  impermanenceModule,
  lib,
  system,
}:
let
  rawPath =
    release:
    if release == "unstable" then "unstable/vpsadminos.nix" else "stable/vpsadminos-${release}.nix";
  raw = base: release: import (base + "/os/lib/nixos-container/${rawPath release}");
  evaluate =
    release: module: extra:
    (fixtures.${release}.lib.nixosSystem {
      inherit system;
      modules = [
        module
        {
          system.stateVersion = "22.11";
          fileSystems."/" = {
            device = "none";
            fsType = "tmpfs";
          };
        }
      ]
      ++ extra;
    }).config;
  persistence = {
    imports = [ impermanenceModule ];
    environment.persistence."/persistent" = {
      hideMounts = true;
      directories = [
        "/var/lib/nixos"
        "/var/log"
      ];
    };
  };
  bind = what: where: {
    inherit what where;
    type = "none";
    options = "bind,x-gvfs-hide";
  };
  manual = mounts: { systemd.mounts = mounts; };
  persistedAncestor = target: {
    imports = [ impermanenceModule ];
    environment.persistence."/persistent".directories = [ target ];
  };
  filesystem = device: target: fsType: options: {
    fileSystems.${target} = { inherit device fsType options; };
  };
  contains = needle: text: lib.hasInfix (builtins.unsafeDiscardStringContext needle) text;
  position =
    needle: text:
    (lib.findFirst (entry: contains needle entry.line) { index = -1; } (
      lib.imap0 (index: line: { inherit index line; }) (lib.splitString "\n" text)
    )).index;
  count = needle: text: builtins.length (lib.filter (contains needle) (lib.splitString "\n" text));
  before =
    first: second: text:
    position first text >= 0 && position second text >= 0 && position first text < position second text;
  check = label: condition: if condition then true else throw "Persistence check failed: ${label}";
  script = c: c.system.activationScripts.script;
  mounts = c: c.system.build.earlyMountScript.text;
  force = c: builtins.deepSeq [ (script c) (mounts c) c.system.dryActivationScript ] true;
  adapted =
    c:
    before "source ${c.system.build.earlyMountScript}" "-update-users-groups.pl" (script c)
    && builtins.elem "specialfs" c.system.activationScripts.users.deps
    && count "source ${c.system.build.earlyMountScript}" (script c) == 1
    && count "specialMount()" (script c) == 1
    && contains "vpsadminosMountRequired" c.system.activationScripts.specialfs.text
    && force c;
  noExactBinds =
    c:
    lib.all (path: !(builtins.hasAttr path c.boot.specialFileSystems)) [
      "/var/lib/nixos"
      "/var/log"
    ];
  checkRelease =
    release:
    let
      current = extra: evaluate release (raw source release) extra;
      baseline = extra: evaluate release (raw oldSource release) extra;
      ordinary = current [ ];
      persisted = current [ persistence ];
      copied = builtins.toFile "vpsadminos-persistence-${release}.nix" (
        builtins.readFile (source + "/os/lib/nixos-container/${rawPath release}")
      );
      standalone = evaluate release (import copied) [ persistence ];
      alternative =
        base: backend:
        evaluate release (raw base release) [
          persistence
          {
            systemd.sysusers.enable = backend == "sysusers";
            services.userborn.enable = backend == "userborn";
          }
        ];
      ancestry = current [
        (manual [
          (bind "/persistent/state" "/var/lib/nixos")
          (bind "/var/lib/nixos/log" "/var/log")
        ])
      ];
      dependent = current [
        (manual [
          (bind "/persistent/state" "/var/lib/nixos")
          (bind "/var/lib/nixos/usr" "/usr")
        ])
      ];
      root = current [ (manual [ (bind "/root-state/nixos" "/var/lib/nixos") ]) ];
      declared = current [
        (manual [ (bind "/custom/backing/state" "/var/lib/nixos") ])
        {
          fileSystems."/custom/backing" = {
            device = "/host/custom";
            fsType = "none";
            options = [ "bind" ];
            neededForBoot = true;
          };
        }
      ];
      nearPrefix = current [
        (manual [ (bind "/custom/backing-other/state" "/var/lib/nixos") ])
        {
          fileSystems."/custom/backing" = {
            device = "/host/custom";
            fsType = "none";
            options = [ "bind" ];
            neededForBoot = true;
          };
        }
      ];
      nonBind = current [
        (manual [ (bind "/custom/backing/state" "/var/lib/nixos") ])
        {
          fileSystems."/custom/backing" = {
            device = "tmpfs";
            fsType = "tmpfs";
            neededForBoot = true;
          };
        }
      ];
      cycle = current [
        (manual [
          (bind "/var/log/state" "/var/lib/nixos")
          (bind "/var/lib/nixos/log" "/var/log")
        ])
      ];
      # The upstream builder selects .result directly, so a deliberate cycle
      # produces a hard missing-attribute error that tryEval cannot catch.
      # Inspect the same pinned upstream topology without building its script.
      cycleUtils = import (fixtures.${release}.source + "/nixos/lib/utils.nix") {
        config = cycle;
        lib = fixtures.${release}.lib;
        pkgs = import fixtures.${release}.source { inherit system; };
      };
      cycleOrder = fixtures.${release}.lib.toposort cycleUtils.fsBefore (
        builtins.attrValues cycle.boot.specialFileSystems
      );
      forced = current [
        persistence
        { system.activationScripts.specialfs = lib.mkForce "guest-specialfs"; }
      ];
      direct = current [
        {
          fileSystems."/var/log" = {
            device = "/direct/log";
            fsType = "none";
            options = [ "bind" ];
          };
        }
      ];
      ancestorVar = current [ (persistedAncestor "/var") ];
      ancestorLib = current [ (persistedAncestor "/var/lib") ];
      directState = current [ (filesystem "/direct/state" "/var/lib/nixos" "none" [ "bind" ]) ];
      directNonBind = current [
        (filesystem "tmpfs" "/var/log" "tmpfs" [
          "defaults"
          "mode=0755"
        ])
      ];
      rbind = current [
        (filesystem "/recursive/var" "/var" "auto" [
          "rbind"
          "ro"
        ])
      ];
      effective = current [
        (manual [ (bind "/original/state" "/var/lib/nixos") ])
        {
          boot.specialFileSystems."/var/lib/nixos" = lib.mkForce {
            device = "/effective/state";
            fsType = "auto";
            options = [
              "rbind"
              "ro"
            ];
            depends = [ "/explicit" ];
          };
          fileSystems."/explicit" = {
            device = "tmpfs";
            fsType = "tmpfs";
            neededForBoot = true;
          };
        }
      ];
      controls = {
        disabled = {
          boot.specialFileSystems."/var" = {
            enable = false;
            device = "tmpfs";
            fsType = "tmpfs";
          };
        };
        near = {
          boot.specialFileSystems."/var/log-old" = {
            device = "/other";
            fsType = "none";
            options = [ "bind" ];
          };
        };
        nearVariable = {
          boot.specialFileSystems."/variable" = {
            device = "/other";
            fsType = "none";
            options = [ "bind" ];
          };
        };
        nearState = {
          boot.specialFileSystems."/var/lib/nixos-other" = {
            device = "/other";
            fsType = "none";
            options = [ "bind" ];
          };
        };
        rootOnly = { };
      };
      transitive = current [
        (filesystem "/bridge/state" "/var/lib/nixos" "none" [ "bind" ])
        {
          fileSystems."/bridge" = {
            device = "/required/bridge";
            fsType = "none";
            options = [ "bind" ];
            neededForBoot = true;
          };
          fileSystems."/required" = {
            device = "/host/required";
            fsType = "none";
            options = [ "rbind" ];
            neededForBoot = true;
          };
          fileSystems."/unrelated" = {
            device = "tmpfs";
            fsType = "tmpfs";
            neededForBoot = true;
          };
        }
      ];
      old = baseline [ persistence ];
      upstreamSource = "source ${persisted.system.build.earlyMountScript}";
    in
    {
      actualRelease = persisted.system.nixos.release;
      legacyOrder = check "${release} global specialfs before real allocator" (
        before upstreamSource "-update-users-groups.pl" (script persisted)
        && builtins.elem "specialfs" persisted.system.activationScripts.users.deps
        && count upstreamSource (script persisted) == 1
        && count "specialMount()" (script persisted) == 1
        && force persisted
      );
      promotion = check "${release} complete promotion and units/options" (
        mounts persisted == mounts old
        &&
          lib.all
            (
              target:
              persisted.boot.specialFileSystems.${target}.options == [
                "bind"
                "x-gvfs-hide"
              ]
              && lib.any (m: m.where == target && m.options == "bind,x-gvfs-hide") persisted.systemd.mounts
            )
            [
              "/var/lib/nixos"
              "/var/log"
            ]
      );
      standalone = check "${release} copied self-contained file" (script standalone == script persisted);
      dry = check "${release} dry omits mounts and prep" (
        lib.all
          (
            c:
            !contains "vpsadminosPrepareStateDirectory" c.system.dryActivationScript
            && !contains "source ${c.system.build.earlyMountScript}" c.system.dryActivationScript
            && contains "-update-users-groups.pl" c.system.dryActivationScript
          )
          [
            persisted
            ancestorVar
            ancestorLib
            directState
            directNonBind
            rbind
            effective
          ]
      );
      ordinary = check "${release} ordinary exact baseline equivalence" (
        script ordinary == script (baseline [ ])
        && ordinary.system.dryActivationScript == (baseline [ ]).system.dryActivationScript
        && force ordinary
      );
      alternatives = lib.genAttrs [ "sysusers" "userborn" ] (
        backend:
        let
          c = alternative source backend;
          b = alternative oldSource backend;
        in
        check "${release} ${backend} exact baseline equivalence" (
          c.system.activationScripts.users == ""
          && script c == script b
          && c.system.dryActivationScript == b.system.dryActivationScript
          && force c
        )
      );
      ancestry = check "${release} selected source ancestry" (
        before "\"/persistent/state\" \"/var/lib/nixos\"" "\"/var/lib/nixos/log\" \"/var/log\"" (
          mounts ancestry
        )
        && force ancestry
      );
      topology = check "${release} valid selected-to-ordinary topology" (
        before "\"/persistent/state\" \"/var/lib/nixos\"" "\"/var/lib/nixos/usr\" \"/usr\"" (
          mounts dependent
        )
        && force dependent
      );
      root = check "${release} root-backed source allowed" (
        force root
        && contains (lib.escapeShellArg "/root-state/nixos") root.system.activationScripts.specialfs.text
      );
      declared = check "${release} declared backing in original global order" (
        before "\"/host/custom\" \"/custom/backing\"" "\"/custom/backing/state\" \"/var/lib/nixos\"" (
          mounts declared
        )
        && contains (lib.escapeShellArgs [
          "bind"
          "/host/custom"
          "/custom/backing"
        ]) declared.system.activationScripts.specialfs.text
        && force declared
      );
      pathComponents = check "${release} backing checks respect path components" (
        !contains (lib.escapeShellArgs [
          "bind"
          "/host/custom"
          "/custom/backing"
        ]) nearPrefix.system.activationScripts.specialfs.text
        && force nearPrefix
      );
      nonBindBacking = check "${release} non-bind backing retains presence-only check" (
        contains (lib.escapeShellArgs [
          "filesystem"
          "tmpfs"
          "/custom/backing"
        ]) nonBind.system.activationScripts.specialfs.text
        && force nonBind
      );
      cycle = check "${release} upstream topology reports the selected-bind cycle" (
        !(cycleOrder ? result)
        && cycleOrder ? cycle
        && cycleOrder.cycle != [ ]
        && lib.all (path: builtins.elem path (map (mount: mount.mountPoint) cycleOrder.cycle)) [
          "/var/lib/nixos"
          "/var/log"
        ]
      );
      mkForce = check "${release} guest mkForce retains precedence" (
        forced.system.activationScripts.specialfs == "guest-specialfs" && force forced
      );
      direct = check "${release} direct filesystems checked before allocation" (
        adapted direct
        && adapted directState
        && adapted directNonBind
        && adapted rbind
        && contains (lib.escapeShellArg "/direct/log") direct.system.activationScripts.specialfs.text
        && lib.all (option: builtins.elem option directNonBind.boot.specialFileSystems."/var/log".options) [
          "defaults"
          "mode=0755"
        ]
        && contains (lib.escapeShellArg (
          lib.concatStringsSep "," directNonBind.boot.specialFileSystems."/var/log".options
        )) directNonBind.system.activationScripts.specialfs.text
        && lib.all (option: builtins.elem option rbind.boot.specialFileSystems."/var".options) [
          "rbind"
          "ro"
        ]
        && contains (lib.escapeShellArg (
          lib.concatStringsSep "," rbind.boot.specialFileSystems."/var".options
        )) rbind.system.activationScripts.specialfs.text
      );
      ancestors = check "${release} impermanence ancestors without exact state/log entries" (
        adapted ancestorVar
        && adapted ancestorLib
        && noExactBinds ancestorVar
        && noExactBinds ancestorLib
        && contains (lib.escapeShellArg "/var") ancestorVar.system.activationScripts.specialfs.text
        && contains (lib.escapeShellArg "/var/lib") ancestorLib.system.activationScripts.specialfs.text
      );
      effectiveEntry = check "${release} effective source/type/options/dependencies" (
        adapted effective
        && effective.boot.specialFileSystems."/var/lib/nixos".device == "/effective/state"
        && effective.boot.specialFileSystems."/var/lib/nixos".fsType == "auto"
        &&
          effective.boot.specialFileSystems."/var/lib/nixos".options == [
            "rbind"
            "ro"
          ]
        && effective.boot.specialFileSystems."/var/lib/nixos".depends == [ "/explicit" ]
        && contains (lib.escapeShellArg "/effective/state") effective.system.activationScripts.specialfs.text
        && contains (lib.escapeShellArg "rbind,ro") effective.system.activationScripts.specialfs.text
        && !contains (lib.escapeShellArg "/original/state") effective.system.activationScripts.specialfs.text
        && contains (lib.escapeShellArg "/explicit") effective.system.activationScripts.specialfs.text
      );
      selectionControls = lib.mapAttrs (
        name: extra:
        check "${release} ${name} does not enable adapter" (
          let
            c = current [ extra ];
          in
          !contains "vpsadminosMountRequired" (script c) && force c
        )
      ) controls;
      requiredPredecessors =
        check "${release} transitive required membership without unrelated callbacks"
          (
            adapted transitive
            && before "\"/host/required\" \"/required\"" "\"/required/bridge\" \"/bridge\"" (mounts transitive)
            && before "\"/required/bridge\" \"/bridge\"" "\"/bridge/state\" \"/var/lib/nixos\"" (
              mounts transitive
            )
            && contains (lib.escapeShellArg "/host/required") transitive.system.activationScripts.specialfs.text
            && contains (lib.escapeShellArg "/required/bridge") transitive.system.activationScripts.specialfs.text
            && !contains (lib.escapeShellArg "/unrelated") transitive.system.activationScripts.specialfs.text
          );
    };
  shellConfig =
    release: mode:
    let
      target =
        if mode == "var" then
          "/var"
        else if mode == "var-lib" then
          "/var/lib"
        else
          "/var/lib/nixos";
      sourcePath =
        if mode == "transitive" then "/fixture/bridge/state" else "/fixture/backing storage/nixos";
      exact = builtins.elem mode [
        "declared"
        "undeclared"
        "filesystem"
      ];
    in
    evaluate release (raw source release) (
      [
        (
          if mode == "nonbind" then
            filesystem "/fixture/device-file" "/var/log" "tmpfs" [
              "defaults"
              "mode=0755"
            ]
          else if
            builtins.elem mode [
              "direct"
              "rbind"
              "transitive"
              "explicit"
            ]
          then
            filesystem sourcePath target "auto" [
              (if mode == "rbind" then "rbind" else "bind")
              "x-gvfs-hide"
            ]
          else
            manual (
              [ (bind sourcePath target) ] ++ lib.optional exact (bind "/fixture/backing storage/log" "/var/log")
            )
        )
      ]
      ++
        lib.optional
          (builtins.elem mode [
            "declared"
            "filesystem"
          ])
          {
            fileSystems."/fixture/backing storage" = {
              device = if mode == "filesystem" then "tmpfs" else "/fixture/host storage";
              fsType = if mode == "filesystem" then "tmpfs" else "none";
              options = if mode == "filesystem" then [ "defaults" ] else [ "bind" ];
              neededForBoot = true;
            };
          }
      ++ lib.optional (mode == "transitive") {
        fileSystems."/fixture/backing storage" = {
          device = "/fixture/host storage";
          fsType = "none";
          options = [ "rbind" ];
          neededForBoot = true;
        };
        fileSystems."/fixture/bridge" = {
          device = "/fixture/backing storage/bridge";
          fsType = "none";
          options = [ "bind" ];
          neededForBoot = true;
        };
      }
      ++ lib.optional (mode == "explicit") {
        fileSystems."/var/lib/nixos".depends = [ "/fixture/dependency" ];
        fileSystems."/fixture/dependency" = {
          device = "fixture-dependency";
          fsType = "tmpfs";
          neededForBoot = true;
        };
        fileSystems."/fixture/unrelated" = {
          device = "fixture-unrelated";
          fsType = "tmpfs";
          neededForBoot = true;
        };
      }
    );
in
{
  assertions = {
    releases = lib.genAttrs [ "25.11" "26.05" "unstable" ] checkRelease;
    latestStable = check "latest stable equals self-contained 26.05" (
      builtins.readFile (source + "/os/lib/nixos-container/stable/vpsadminos.nix")
      == builtins.readFile (source + "/os/lib/nixos-container/stable/vpsadminos-26.05.nix")
    );
  };
  shellFixtures = builtins.listToAttrs (
    lib.concatMap
      (
        release:
        map
          (
            mode:
            let
              c = shellConfig release mode;
            in
            {
              name = "${release}-${mode}";
              value = {
                snippet = c.system.activationScripts.specialfs.text;
                earlyMountScript = c.system.build.earlyMountScript;
                selectedOptions =
                  lib.concatStringsSep ","
                    c.boot.specialFileSystems.${
                      if mode == "var" then
                        "/var"
                      else if mode == "var-lib" then
                        "/var/lib"
                      else if mode == "nonbind" then
                        "/var/log"
                      else
                        "/var/lib/nixos"
                    }.options;
                inherit mode;
              };
            }
          )
          [
            "declared"
            "undeclared"
            "filesystem"
            "var"
            "var-lib"
            "direct"
            "rbind"
            "nonbind"
            "transitive"
            "explicit"
          ]
      )
      [
        "25.11"
        "26.05"
        "unstable"
      ]
  );
}
