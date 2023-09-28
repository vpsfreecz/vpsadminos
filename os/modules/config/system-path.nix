{ config, lib, pkgs, ... }:

# based heavily on https://github.com/NixOS/nixpkgs/blob/master/nixos/modules/config/system-path.nix

with lib;

let
  zfstools_ovl = pkgs.callPackage <nixpkgs/pkgs/tools/filesystems/zfstools/default.nix> { zfs = config.boot.zfsUserPackage; };
  requiredPackages = with pkgs; [
    zfstools_ovl
    util-linux
    coreutils
    iproute
    iputils
    iptables
    mingetty
    procps
    bashInteractive
    runit
    shadow
    kmod
    xz
    gzip
    gnused
    gnugrep
    gnutar
    cpio
    curl
    diffutils
    findutils
    man
    netcat
    procps
    psmisc
    rsync
    time
    which
    gawk
    wget
    gnupg
    bzip2
    bridge-utils
    nettools
    bird
    su
    lxcfs
    pciutils
    eudev
    rsyslog-light
  ];
in
{
  options = {
    environment = {
      systemPackages = mkOption {
        type = types.listOf types.package;
        default = [];
        example = literalExpression "[ pkgs.firefox pkgs.thunderbird ]";
      };
      pathsToLink = mkOption {
        type = types.listOf types.str;
        default = [];
        example = ["/"];
        description = "List of directories to be symlinked in <filename>/run/current-system/sw</filename>.";
      };
      extraOutputsToInstall = mkOption {
        type = types.listOf types.str;
        default = [ ];
        example = [ "doc" "info" "docdev" ];
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
    environment.systemPackages = requiredPackages;
    environment.pathsToLink = [ "/bin" "/lib" "/man" "/share/man" ];
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
