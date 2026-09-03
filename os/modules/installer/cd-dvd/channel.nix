# Provide initial local Nixpkgs/vpsAdminOS source paths so the installer can
# build flake-based configurations without fetching the sources first.

{
  config,
  lib,
  pkgs,
  nixpkgsPath,
  ...
}:

with lib;

let
  nixpkgs = lib.cleanSource nixpkgsPath;

  os = (
    builtins.filterSource (
      path: type:
      (lib.cleanSourceFilter path type)
      && (!lib.hasSuffix "img" (baseNameOf path))
      && (!hasInfix "/os/result/" path)
      && (baseNameOf path != "local.nix")
    ) ../../../.
  );

  ctStartMenu = builtins.filterSource (
    path: type: (lib.cleanSourceFilter path type) && (baseNameOf path != "ctstartmenu") # exclude the locally-built binary
  ) ../../../../ctstartmenu;

  ctPtyWrapper = builtins.filterSource (
    path: type: (lib.cleanSourceFilter path type)
  ) ../../../../ctptywrapper;

  imageScripts = builtins.filterSource (
    path: type: (lib.cleanSourceFilter path type)
  ) ../../../../image-scripts;

  rubySource = src: builtins.filterSource (path: type: lib.cleanSourceFilter path type) src;

  rubySources = {
    libosctl = rubySource ../../../../libosctl;
    osctl = rubySource ../../../../osctl;
    osctl-exporter = rubySource ../../../../osctl-exporter;
    osctl-exportfs = rubySource ../../../../osctl-exportfs;
    osctl-image = rubySource ../../../../osctl-image;
    osctl-oomd = rubySource ../../../../osctl-oomd;
    osctl-repo = rubySource ../../../../osctl-repo;
    osctld = rubySource ../../../../osctld;
    osctlEnvExec = rubySource ../../../../tools/osctl-env-exec;
    osup = rubySource ../../../../osup;
    osvm = rubySource ../../../../osvm;
    svctl = rubySource ../../../../svctl;
    test-runner = rubySource ../../../../test-runner;
  };

  # Reflink metadata is allocated with the source extent, so cloning can fail
  # when that allocation group is full even if the filesystem has free space.
  nixosChannel = pkgs.runCommand "nixos-${config.system.vpsadminos.version}" { } ''
    mkdir $out
    cp --reflink=never -prd ${nixpkgs} $out/nixos
    chmod -R u+w $out/nixos
    if [ ! -e $out/nixos/nixpkgs ]; then
      ln -s . $out/nixos/nixpkgs
    fi
  '';

  vpsadminosChannel = pkgs.runCommand "vpsadminos-${config.system.vpsadminos.version}" { } ''
    mkdir -p $out $out/vpsadminos $out/vpsadminos/artwork
    cp --reflink=never -prd ${../../../../flake.nix} $out/vpsadminos/flake.nix
    cp --reflink=never -prd ${../../../../flake.lock} $out/vpsadminos/flake.lock
    cp --reflink=never -prd ${../../../../.ruby-version} $out/vpsadminos/.ruby-version
    cp --reflink=never -prd ${ctStartMenu} $out/vpsadminos/ctstartmenu
    cp --reflink=never -prd ${ctPtyWrapper} $out/vpsadminos/ctptywrapper
    cp --reflink=never -prd ${imageScripts} $out/vpsadminos/image-scripts
    cp --reflink=never -prd ${rubySources.libosctl} $out/vpsadminos/libosctl
    cp --reflink=never -prd ${rubySources.osctl} $out/vpsadminos/osctl
    cp --reflink=never -prd ${rubySources.osctl-exporter} $out/vpsadminos/osctl-exporter
    cp --reflink=never -prd ${rubySources.osctl-exportfs} $out/vpsadminos/osctl-exportfs
    cp --reflink=never -prd ${rubySources.osctl-image} $out/vpsadminos/osctl-image
    cp --reflink=never -prd ${rubySources.osctl-oomd} $out/vpsadminos/osctl-oomd
    cp --reflink=never -prd ${rubySources.osctl-repo} $out/vpsadminos/osctl-repo
    cp --reflink=never -prd ${rubySources.osctld} $out/vpsadminos/osctld
    mkdir -p $out/vpsadminos/tools
    cp --reflink=never -prd ${rubySources.osctlEnvExec} $out/vpsadminos/tools/osctl-env-exec
    cp --reflink=never -prd ${rubySources.osup} $out/vpsadminos/osup
    cp --reflink=never -prd ${rubySources.osvm} $out/vpsadminos/osvm
    cp --reflink=never -prd ${rubySources.svctl} $out/vpsadminos/svctl
    cp --reflink=never -prd ${rubySources.test-runner} $out/vpsadminos/test-runner
    cp --reflink=never -prd ${os} $out/vpsadminos/os
    cp --reflink=never -prd ${../../../../artwork/boot.png} $out/vpsadminos/artwork/boot.png
    chmod -R u+w $out/vpsadminos
    echo -n ${config.system.vpsadminos.release} > $out/vpsadminos/.version
    echo -n ${config.system.vpsadminos.versionSuffix} > $out/vpsadminos/.version-suffix
    echo -n ${config.system.vpsadminos.revision} > $out/vpsadminos/.git-revision
    echo ${config.system.vpsadminos.versionSuffix} | sed -e s/pre// > $out/vpsadminos/svn-revision
  '';

in

{
  options = {
    os.channel-registration.enable = mkOption {
      type = types.bool;
      default = false;
    };
  };

  config = mkIf config.os.channel-registration.enable {
    # Provide the vpsAdminOS/Nixpkgs sources. This is required by the installer
    # to generate local flake inputs on offline systems.
    runit.services.channel-registration = {
      run = ''
        ensureServiceStarted eudev-trigger
        set -e
        if ! [ -e /var/lib/nixos/did-channel-init ]; then
          echo "registering local Nixpkgs/vpsAdminOS sources..."
          mkdir -p /nix/var/nix/profiles/per-user/root/channels
          ln -sfn ${nixosChannel}/nixos /nix/var/nix/profiles/per-user/root/channels/nixos
          ln -sfn ${vpsadminosChannel}/vpsadminos /nix/var/nix/profiles/per-user/root/channels/vpsadminos
          mkdir -m 0700 -p /root/.nix-defexpr
          ln -sfn /nix/var/nix/profiles/per-user/root/channels /root/.nix-defexpr/channels
          mkdir -m 0755 -p /var/lib/nixos
          touch /var/lib/nixos/did-channel-init
        fi
      '';
      oneShot = true;
    };
  };
}
