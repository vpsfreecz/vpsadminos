{ pkgs, config, lib, ... }:

with lib;

let
  systemBuilder =
    let
      serviceList = pkgs.writeText "services.json" (builtins.toJSON {
        defaultRunlevel = config.runit.defaultRunlevel;

        services = lib.mapAttrs (k: v: {
          inherit (v) runlevels onChange reloadMethod;
        }) config.runit.services;
      });
    in ''
      mkdir $out
      cp ${config.system.build.bootStage2} $out/init
      substituteInPlace $out/init --subst-var-by systemConfig $out
      ln -s ${config.system.build.etc}/etc $out/etc
      ln -s ${config.system.path} $out/sw
      echo -n "$vpsadminosLabel" > $out/os-version
      ln -s ${serviceList} $out/services

      echo "$activationScript" > $out/activate
      echo "$dryActivationScript" > $out/dry-activate
      substituteInPlace $out/activate --subst-var out
      substituteInPlace $out/dry-activate --subst-var out
      chmod u+x $out/activate $out/dry-activate
      unset activationScript dryActivationScript

      mkdir $out/bin
      substituteAll ${./switch-to-configuration.rb} $out/bin/switch-to-configuration
      chmod +x $out/bin/switch-to-configuration

      ${optionalString (pkgs.stdenv.hostPlatform == pkgs.stdenv.buildPlatform) ''
        if ! output=$($ruby/bin/ruby -c $out/bin/switch-to-configuration 2>&1); then
          echo "switch-to-configuration syntax is not valid:"
          echo "$output"
          exit 1
        fi
      ''}

      ${config.system.systemBuilderCommands}

      cp "$extraDependenciesPath" "$out/extra-dependencies"

      ${config.system.extraSystemBuilderCmds}
    '';

  # Putting it all together.  This builds a store path containing
  # symlinks to the various parts of the built configuration (the
  # kernel, systemd units, init scripts, etc.) as well as a script
  # `switch-to-configuration' that activates the configuration and
  # makes it bootable.
  baseSystem = pkgs.stdenvNoCC.mkDerivation ({
    name = "vpsadminos-system-${config.system.name}-${config.system.vpsadminos.label}";
    preferLocalBuild = true;
    allowSubstitutes = false;
    passAsFile = [ "extraDependencies" ];
    buildCommand = systemBuilder;

    inherit (pkgs) coreutils;
    shell = "${pkgs.bash}/bin/sh";
    su = "${pkgs.shadow.su}/bin/su";
    utillinux = pkgs.util-linux;
    ruby = pkgs.ruby;

    kernelParams = config.boot.kernelParams;
    installBootLoader = config.system.build.installBootLoader;
    activationScript = config.system.activationScripts.script;
    dryActivationScript = config.system.dryActivationScript;
    vpsadminosLabel = config.system.vpsadminos.label;

    inherit (config.system) extraDependencies;
  } // config.system.systemBuilderArgs);

  # Handle assertions and warnings

  failedAssertions = map (x: x.message) (filter (x: !x.assertion) config.assertions);

  baseSystemAssertWarn = if failedAssertions != []
    then throw "\nFailed assertions:\n${concatStringsSep "\n" (map (x: "- ${x}") failedAssertions)}"
    else showWarnings config.warnings baseSystem;

  # Replace runtime dependencies
  system = foldr ({ oldDependency, newDependency }: drv:
      pkgs.replaceDependency { inherit oldDependency newDependency drv; }
    ) baseSystemAssertWarn config.system.replaceRuntimeDependencies;

  systemWithBuildDeps = system.overrideAttrs (o: {
    systemBuildClosure = pkgs.closureInfo { rootPaths = [ system.drvPath ]; };
    buildCommand = o.buildCommand + ''
      ln -sn $systemBuildClosure $out/build-closure
    '';
  });

in {
  options = {
    system.boot.loader.id = mkOption {
      internal = true;
      default = "";
      description = lib.mdDoc ''
        Id string of the used bootloader.
      '';
    };

    system.boot.loader.kernelFile = mkOption {
      internal = true;
      default = pkgs.stdenv.hostPlatform.linux-kernel.target;
      defaultText = literalExpression "pkgs.stdenv.hostPlatform.linux-kernel.target";
      type = types.str;
      description = lib.mdDoc ''
        Name of the kernel file to be passed to the bootloader.
      '';
    };

    system.boot.loader.initrdFile = mkOption {
      internal = true;
      default = "initrd";
      type = types.str;
      description = lib.mdDoc ''
        Name of the initrd file to be passed to the bootloader.
      '';
    };

    system.build = {
      toplevel = mkOption {
        type = types.package;
        readOnly = true;
        description = lib.mdDoc ''
          This option contains the store path that typically represents a vpsAdminOSsystem.

          You can read this path in a custom deployment tool for example.
        '';
      };

      squashfs = mkOption {
        type = types.package;
        readOnly = true;
        description = lib.mdDoc ''
          This options contains the store path to a squashfs image of the system
        '';
      };

      dist = mkOption {
        type = types.package;
        readOnly = true;
        description = lib.mdDoc ''
          This options contains the store path to a directory with essential files
          to boot this system from PXE
        '';
      };
    };

    system.distBuilderCommands = mkOption {
      type = types.lines;
      internal = true;
      default = "";
      description = ''
        This code will be added to the builder creating the dist store path.
      '';
    };

    system.systemBuilderCommands = mkOption {
      type = types.lines;
      internal = true;
      default = "";
      description = ''
        This code will be added to the builder creating the system store path.
      '';
    };

    system.systemBuilderArgs = mkOption {
      type = types.attrsOf types.unspecified;
      internal = true;
      default = {};
      description = lib.mdDoc ''
        `lib.mkDerivation` attributes that will be passed to the top level system builder.
      '';
    };

    system.forbiddenDependenciesRegex = mkOption {
      default = "";
      example = "-dev$";
      type = types.str;
      description = lib.mdDoc ''
        A POSIX Extended Regular Expression that matches store paths that
        should not appear in the system closure, with the exception of {option}`system.extraDependencies`, which is not checked.
      '';
    };

    system.extraSystemBuilderCmds = mkOption {
      type = types.lines;
      internal = true;
      default = "";
      description = lib.mdDoc ''
        This code will be added to the builder creating the system store path.
      '';
    };

    system.extraDependencies = mkOption {
      type = types.listOf types.package;
      default = [];
      description = lib.mdDoc ''
        A list of packages that should be included in the system
        closure but generally not visible to users.

        This option has also been used for build-time checks, but the
        `system.checks` option is more appropriate for that purpose as checks
        should not leave a trace in the built system configuration.
      '';
    };

    system.checks = mkOption {
      type = types.listOf types.package;
      default = [];
      description = lib.mdDoc ''
        Packages that are added as dependencies of the system's build, usually
        for the purpose of validating some part of the configuration.

        Unlike `system.extraDependencies`, these store paths do not
        become part of the built system configuration.
      '';
    };

    system.replaceRuntimeDependencies = mkOption {
      default = [];
      example = lib.literalExpression "[ ({ original = pkgs.openssl; replacement = pkgs.callPackage /path/to/openssl { }; }) ]";
      type = types.listOf (types.submodule (
        { ... }: {
          options.original = mkOption {
            type = types.package;
            description = lib.mdDoc "The original package to override.";
          };

          options.replacement = mkOption {
            type = types.package;
            description = lib.mdDoc "The replacement package.";
          };
        })
      );
      apply = map ({ original, replacement, ... }: {
        oldDependency = original;
        newDependency = replacement;
      });
      description = lib.mdDoc ''
        List of packages to override without doing a full rebuild.
        The original derivation and replacement derivation must have the same
        name length, and ideally should have close-to-identical directory layout.
      '';
    };

    system.name = mkOption {
      type = types.str;
      default =
        if config.networking.hostName == ""
        then "unnamed"
        else config.networking.hostName;
      defaultText = literalExpression ''
        if config.networking.hostName == ""
        then "unnamed"
        else config.networking.hostName;
      '';
      description = lib.mdDoc ''
        The name of the system used in the {option}`system.build.toplevel` derivation.

        That derivation has the following name:
        `"vpsadminos-system-''${config.system.name}-''${config.system.vpsadminos.label}"`
      '';
    };

    system.includeBuildDependencies = mkOption {
      type = types.bool;
      default = false;
      description = lib.mdDoc ''
        Whether to include the build closure of the whole system in
        its runtime closure.  This can be useful for making changes
        fully offline, as it includes all sources, patches, and
        intermediate outputs required to build all the derivations
        that the system depends on.

        Note that this includes _all_ the derivations, down from the
        included applications to their sources, the compilers used to
        build them, and even the bootstrap compiler used to compile
        the compilers. This increases the size of the system and the
        time needed to download its dependencies drastically: a
        minimal configuration with no extra services enabled grows
        from ~670MiB in size to 13.5GiB, and takes proportionally
        longer to download.
      '';
    };

    system.storeOverlaySize = mkOption {
      default = "2G";
      type = types.str;
      description = ''
        Size of the tmpfs filesystems used as an overlay for /nix/store.
        See option size in man tmpfs(5) for possible values.
      '';
    };

    boot.isContainer = mkOption {
      type = types.bool;
      default = false;
    };

    boot.isLiveSystem = mkOption {
      type = types.bool;
      default = true;
      description = lib.mdDoc ''
        Set to `true` if this system is being booted e.g. from PXE, i.e. when
        there's no boot loader.
      '';
    };

    boot.predefinedFailAction = mkOption {
      type = types.enum ["" "n" "i" "r" "*" ];
      default = "";
      description = ''
        Action to take automatically if stage-1 fails.

        n - create new pool (may also erase disks and run partitioning if configured)
        i - interactive shell
        r - reboot
        * - ignore

        Useful for unattended installations and testing.
      '';
    };

    boot.enableUnifiedCgroupHierarchy = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Whether to enable the unified cgroup hierarchy (cgroupsv2).

        This feature is experimental.
      '';
    };
  };

  config = {
    system.build.installBootLoader = mkIf config.boot.isLiveSystem "none";

    boot.kernelParams = optional (!config.boot.isLiveSystem) [ "nolive" ];

    system.extraSystemBuilderCmds =
      optionalString
        (config.system.forbiddenDependenciesRegex != "")
        ''
          if [[ $forbiddenDependenciesRegex != "" && -n $closureInfo ]]; then
            if forbiddenPaths="$(grep -E -- "$forbiddenDependenciesRegex" $closureInfo/store-paths)"; then
              echo -e "System closure $out contains the following disallowed paths:\n$forbiddenPaths"
              exit 1
            fi
          fi
        '';

    system.systemBuilderArgs = {
      # Not actually used in the builder. `passedChecks` is just here to create
      # the build dependencies. Checks are similar to build dependencies in the
      # sense that if they fail, the system build fails. However, checks do not
      # produce any output of value, so they are not used by the system builder.
      # In fact, using them runs the risk of accidentally adding unneeded paths
      # to the system closure, which defeats the purpose of the `system.checks`
      # option, as opposed to `system.extraDependencies`.
      passedChecks = concatStringsSep " " config.system.checks;
    }
    // lib.optionalAttrs (config.system.forbiddenDependenciesRegex != "") {
      inherit (config.system) forbiddenDependenciesRegex;
      closureInfo = pkgs.closureInfo { rootPaths = [
        # override to avoid  infinite recursion (and to allow using extraDependencies to add forbidden dependencies)
        (config.system.build.toplevel.overrideAttrs (_: { extraDependencies = []; closureInfo = null; }))
      ]; };
    };

    system.build.toplevel = if config.system.includeBuildDependencies then systemWithBuildDeps else system;

    system.build.squashfs = pkgs.callPackage ../../../lib/make-squashfs.nix {
      storeContents = [ config.system.build.toplevel ];
      secretsDir = config.system.secretsDir;
    };

    system.build.dist = pkgs.runCommand "vpsadminos-dist" {} ''
      mkdir $out
      cp ${config.system.build.squashfs} $out/root.squashfs
      cp ${config.system.build.kernel}/bzImage $out/bzImage
      cp ${config.system.build.initialRamdisk}/initrd $out/initrd
      echo "init=${config.system.build.toplevel}/init ${builtins.unsafeDiscardStringContext (toString config.boot.kernelParams)}" > $out/kernel-params
      ${config.system.distBuilderCommands}
    '';
  };
}
