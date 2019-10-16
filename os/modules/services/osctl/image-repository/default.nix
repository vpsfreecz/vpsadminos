{ config, pkgs, lib, ... }:
with lib;
let
  repository = {
    options = {
      path = mkOption {
        type = types.str;
        description = ''
          Path to the generated image repository.
        '';
      };

      cacheDir = mkOption {
        type = types.str;
        description = ''
          Path to directory where built images are cached before added to the
          repository.
        '';
      };

      logDir = mkOption {
        type = types.str;
        default = "/tmp";
        description = ''
          Directory where build logs will be stored.
        '';
      };

      buildScriptDir = mkOption {
        type = types.str;
        description = ''
          Path to directory with image build scripts for use with osctl-image
        '';
      };

      buildDataset = mkOption {
        type = types.str;
        description = ''
          Name of a dataset used to build images
        '';
      };

      rebuildAll = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Rebuild all images, even when they're found in cacheDir
        '';
      };

      keepAllFailedTests = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Keep containers of all failed tests for further analysis
        '';
      };

      buildInterval = mkOption {
        default = "0 4 * * *";
        type = types.nullOr types.str;
        description = ''
          Date and time expression for when to build images in a crontab
          format, i.e. minute, hour, day of month, month and day of month
          separated by spaces.
        '';
      };

      postBuild = mkOption {
        type = types.lines;
        default = "";
        description = ''
          Shell commands run after all images were built, or attempted to be built
        '';
      };

      vendors = mkOption {
        type = types.attrsOf (types.submodule vendor);
        default = {};
        example = {
          vpsadminos = { defaultVariant = "minimal"; };
        };
        description = ''
          Vendors
        '';
      };

      defaultVendor = mkOption {
        type = types.str;
        example = "vpsadminos";
        description = ''
          Name of the default image vendor
        '';
      };

      images = mkOption {
        type = types.attrsOf (types.attrsOf (types.submodule image));
        default = {};
        description = ''
          Configure container images
        '';
      };

      garbageCollection = mkOption {
        type = types.listOf (types.submodule gc);
        default = [];
        description = ''
          Garbage collection of old images
        '';
      };
    };
  };

  vendor = {
    options = {
      defaultVariant = mkOption {
        type = types.str;
        example = "minimal";
        description = ''
          Name of the default image variant
        '';
      };
    };
  };

  image = {
    options = {
      name = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          Optional image name
        '';
      };

      tags = mkOption {
        type = types.listOf types.str;
        default = [];
        description = ''
          Image tags
        '';
      };

      rebuild = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Rebuild the image even if it is found in cacheDir
        '';
      };

      keepFailedTests = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Keep containers of failed tests for further analysis
        '';
      };
    };
  };

  gc = {
    options = {
      vendor = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          Regular expression to match image vendor
        '';
      };

      variant = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          Regular expression to match image variant
        '';
      };

      arch = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          Regular expression to match image arch
        '';
      };

      distribution = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          Regular expression to match image distribution
        '';
      };

      version = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          Regular expression to match image version
        '';
      };

      keep = mkOption {
        type = types.int;
        description = ''
          Number of matched images to keep
        '';
      };
    };
  };

  createRepositories = cfg: mapAttrsToList createRepository cfg;

  createRepository = repo: cfg: rec {
    buildScript = createBuildScript repo cfg;
    buildScriptBin = "${buildScript}/bin/build-image-repository-${repo}";
    buildInterval = cfg.buildInterval;
  };

  createBuildScript = repo: cfg: pkgs.writeScriptBin "build-image-repository-${repo}" ''
    #!${pkgs.bash}/bin/bash

    export NIX_PATH="nixpkgs=/nix/var/nix/profiles/per-user/root/channels/nixos"

    pushd () {
      command pushd "$@" > /dev/null
    }

    popd () {
      command popd "$@" > /dev/null
    }

    repoDir="${cfg.path}"
    repoCache="${cfg.cacheDir}"
    buildDataset="${cfg.buildDataset}"
    buildScriptDir="${cfg.buildScriptDir}"
    osctlRepo="${pkgs.osctl-repo}/bin/osctl-repo"
    osctlImage="${pkgs.osctl-image}/bin/osctl-image"

    if [ ! -d "$repoDir" ] || [ -z "$(ls -A "$repoDir")" ] ; then
      mkdir -p "$repoDir"
      cd "$repoDir"
      $osctlRepo local init
    else
      cd "$repoDir"
    fi

    mkdir -p "$repoCache"

    ${concatStringsSep "\n\n" (buildImages cfg cfg.images)}

    cd "$repoDir"
    ${concatStringsSep "\n" (setDefaultVariants cfg.vendors)}
    $osctlRepo local default ${cfg.defaultVendor}

    ${gcImages cfg}
    ${cfg.postBuild}
  '';

  buildImages = repoCfg: images: flatten (mapAttrsToList (name: versions:
    mapAttrsToList (version: cfg: ''
      pushd "$buildScriptDir"

      logfile=$(mktemp ${repoCfg.logDir}/${name}.${version}.$(date +%Y%m%d%H%M%S).XXXXXX.log)

      $osctlImage deploy \
        --build-dataset $buildDataset \
        --output-dir "$repoCache" \
        ${optionalString (rebuildImage repoCfg cfg) "--rebuild"} \
        ${optionalString (keepFailed repoCfg cfg) "--keep-failed"} \
        ${concatStringsSep "\\\n  " (imageTagArgs cfg.tags)} \
        ${imageName { inherit name version; customName = cfg.name; }} \
        "$repoDir" > "$logfile" 2>&1

      rc=$?
      if [ $rc == 0 ] ; then
        rm -f "$logfile"
      else
        echo "Build of ${name}.${version} failed with exit status $rc"
        echo "Log file: $logfile"
      fi

      popd
    '') versions
    ) images);

  gcRunner = pkgs.substituteAll {
    name = "container-image-gc.rb";
    src = ./gc.rb;
    isExecutable = true;
    ruby = pkgs.ruby;
    osctlRepo = pkgs.osctl-repo;
  };

  gcConfig = matchers: map (matcher:
    filterAttrs (k: v: k != "_module" ) matcher
  ) matchers;

  gcConfigFile = matchers:
    pkgs.writeText "image-repository-gc-config.json" (builtins.toJSON ({
      gc = gcConfig matchers;
    }));

  gcImages = repoCfg: optionalString (repoCfg.garbageCollection != []) ''
    ${gcRunner} ${gcConfigFile repoCfg.garbageCollection}
  '';

  imageName = { name, version, customName }:
    if customName == null then
      "${name}-${version}"
    else customName;

  imageTagArgs = tags: map (v: "--tag \"${v}\"") tags;

  rebuildImage = repoCfg: imageCfg: repoCfg.rebuildAll || imageCfg.rebuild;

  keepFailed = repoCfg: imageCfg: repoCfg.keepAllFailedTests || imageCfg.keepFailedTests;

  setDefaultVariants = vendors: mapAttrsToList (name: cfg:
    "$osctlRepo local default ${name} ${cfg.defaultVariant}"
  ) vendors;
in
{
  options = {
    services.osctl.image-repository = mkOption {
      type = types.attrsOf (types.submodule repository);
      default = {};
      description = ''
        Configure container image repositories
      '';
    };
  };

  config =
    let
      repos = createRepositories config.services.osctl.image-repository;
      packages = map (repo: repo.buildScript) repos;
      cronjobs = map (repo: "${repo.buildInterval} root ${repo.buildScriptBin}") repos;
    in {
      environment.systemPackages = packages;
      services.cron.systemCronJobs = cronjobs;
    };
}
