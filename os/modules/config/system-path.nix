{
  config,
  lib,
  pkgs,
  ...
}:

# based heavily on https://github.com/NixOS/nixpkgs/blob/master/nixos/modules/config/system-path.nix

with lib;

let
  zfstools_ovl = pkgs.callPackage <nixpkgs/pkgs/by-name/zf/zfstools/package.nix> {
    zfs = config.boot.zfsUserPackage;
  };

  corePackageNames = [
    "bashInteractive"
    "bird2"
    "bridge-utils"
    "bzip2"
    "coreutils"
    "cpio"
    "curl"
    "diffutils"
    "eudev"
    "findutils"
    "gawk"
    "gnugrep"
    "gnupg"
    "gnused"
    "gnutar"
    "gzip"
    "iproute2"
    "iptables"
    "iputils"
    "kmod"
    "man"
    "mingetty"
    "netcat"
    "nettools"
    "pciutils"
    "procps"
    "psmisc"
    "runit"
    "rsyslog-light"
    "shadow"
    "su"
    "time"
    "util-linux"
    "which"
    "xz"
    "wget"
  ];

  corePackages =
    (map (
      n:
      let
        pkg = pkgs.${n};
      in
      lib.setPrio ((pkg.meta.priority or lib.meta.defaultPriority) + 3) pkg
    ) corePackageNames)
    ++ [ pkgs.stdenv.cc.libc ];
  corePackagesText = "[ ${lib.concatMapStringsSep " " (n: "pkgs.${n}") corePackageNames} ]";

  defaultPackageNames = [
    "perl"
    "rsync"
    "strace"
  ];
  defaultPackages = map (
    n:
    let
      pkg = pkgs.${n};
    in
    lib.setPrio ((pkg.meta.priority or lib.meta.defaultPriority) + 3) pkg
  ) defaultPackageNames;
  defaultPackagesText = "[ ${lib.concatMapStringsSep " " (n: "pkgs.${n}") defaultPackageNames} ]";
in
{
  options = {
    environment = {
      systemPackages = mkOption {
        type = types.listOf types.package;
        default = [ ];
        example = literalExpression "[ pkgs.firefox pkgs.thunderbird ]";
      };

      corePackages = lib.mkOption {
        type = lib.types.listOf lib.types.package;
        defaultText = lib.literalMD ''
          these packages, with their `meta.priority` numerically increased
          (thus lowering their installation priority):

              ${corePackagesText}
        '';
        example = [ ];
        description = ''
          Set of core packages for a normal interactive system.

          Only change this if you know what you're doing!

          Like with systemPackages, packages are installed to
          {file}`/run/current-system/sw`. They are
          automatically available to all users, and are
          automatically updated every time you rebuild the system
          configuration.
        '';
      };

      defaultPackages = lib.mkOption {
        type = lib.types.listOf lib.types.package;
        default = defaultPackages;
        defaultText = lib.literalMD ''
          these packages, with their `meta.priority` numerically increased
          (thus lowering their installation priority):

              ${defaultPackagesText}
        '';
        example = [ ];
        description = ''
          Set of default packages that aren't strictly necessary
          for a running system, entries can be removed for a more
          minimal NixOS installation.

          Like with systemPackages, packages are installed to
          {file}`/run/current-system/sw`. They are
          automatically available to all users, and are
          automatically updated every time you rebuild the system
          configuration.
        '';
      };

      pathsToLink = mkOption {
        type = types.listOf types.str;
        default = [ ];
        example = [ "/" ];
        description = "List of directories to be symlinked in <filename>/run/current-system/sw</filename>.";
      };

      extraOutputsToInstall = mkOption {
        type = types.listOf types.str;
        default = [ ];
        example = [
          "doc"
          "info"
          "docdev"
        ];
        description = "List of additional package outputs to be symlinked into <filename>/run/current-system/sw</filename>.";
      };

      extraSetup = mkOption {
        type = types.lines;
        default = "";
        description = lib.mdDoc "Shell fragments to be run after the system environment has been created. This should only be used for things that need to modify the internals of the environment, e.g. generating MIME caches. The environment being built can be accessed at $out.";
      };
    };
    system.path = mkOption {
      internal = true;
    };
  };
  config = {
    environment.corePackages = corePackages ++ [ zfstools_ovl ];

    environment.systemPackages = config.environment.corePackages ++ config.environment.defaultPackages;

    environment.pathsToLink = [
      "/bin"
      "/lib"
      "/man"
      "/share/man"
    ];

    system.path = pkgs.buildEnv {
      name = "system-path";
      paths = config.environment.systemPackages;
      inherit (config.environment) pathsToLink extraOutputsToInstall;
      postBuild = ''
        # Remove wrapped binaries, they shouldn't be accessible via PATH.
        find $out/bin -maxdepth 1 -name ".*-wrapped" -type l -delete

        if [ -x $out/bin/glib-compile-schemas -a -w $out/share/glib-2.0/schemas ]; then
            $out/bin/glib-compile-schemas $out/share/glib-2.0/schemas
        fi

        ${config.environment.extraSetup}
      '';
    };
  };
}
