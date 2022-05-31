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

      enableCronJob = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Enable cron job run at
          <option>osctl.image-repository.&lt;name&gt;.buildInterval</option>
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
    enableCronJob = cfg.enableCronJob;
    buildInterval = cfg.buildInterval;
  };

  buildConfig = repo: cfg: {
    repo_dir = cfg.path;
    cache_dir = cfg.cacheDir;
    log_dir = cfg.logDir;
    dataset = cfg.buildDataset;
    script_dir = cfg.buildScriptDir;
    osctl_repo = pkgs.osctl-repo;
    osctl_image = pkgs.osctl-image;
    images = cfg.images;
    rebuild = cfg.rebuildAll;
    keep_failed_tests = cfg.keepAllFailedTests;
    default_vendor_variants = mapAttrs (name: vendorCfg: vendorCfg.defaultVariant) cfg.vendors;
    default_vendor = cfg.defaultVendor;
    post_build = pkgs.writers.writeBash "repo-${repo}-post-build.sh" cfg.postBuild;
    gc =
      if cfg.garbageCollection == [] then
        null
      else
        [gcRunner (gcConfigFile cfg.garbageCollection)];
  };

  buildScript = repo: cfg: pkgs.substituteAll {
    src = ./build.rb;
    isExecutable = true;
    ruby = pkgs.ruby;
    json_config = pkgs.writeText "repo-${repo}-config.json" (builtins.toJSON (buildConfig repo cfg));
  };

  createBuildScript = repo: cfg: pkgs.runCommand "repo-${repo}-build" {} ''
    mkdir -p $out/bin
    ln -s ${buildScript repo cfg} $out/bin/build-image-repository-${repo}
  '';

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
      cronjobs = flatten (map (repo:
        optional repo.enableCronJob "${repo.buildInterval} root ${repo.buildScriptBin}"
      ) repos);
    in {
      environment.systemPackages = packages;
      services.cron.systemCronJobs = cronjobs;
    };
}
