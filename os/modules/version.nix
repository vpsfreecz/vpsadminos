{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.system;

  releaseFile  = ../../.version;
  suffixFile   = ../../.version-suffix;
  revisionFile = ../../.git-revision;
  gitRepo      = ../../.git;
  gitCommitId  = lib.substring 0 7 (commitIdFromGitRepo gitRepo);

  nixpkgsRepo  = "${toString pkgs.path}/.git";
in

{

  options.system = {

    stateVersion = mkOption {
      type = types.str;
      default = cfg.osRelease;
      description = ''
        Every once in a while, a new vpsAdminOS release may change
        configuration defaults in a way incompatible with stateful
        data. For instance, if the default version of PostgreSQL
        changes, the new version will probably be unable to read your
        existing databases. To prevent such breakage, you can set the
        value of this option to the vpsAdminOS release with which you want
        to be compatible. The effect is that vpsAdminOS will option
        defaults corresponding to the specified release (such as using
        an older version of PostgreSQL).
      '';
    };

    osLabel = mkOption {
      type = types.str;
      description = ''
        Label to be used in the names of generated outputs and boot
        labels.
      '';
    };

    osVersion = mkOption {
      internal = true;
      type = types.str;
      description = "The full vpsAdminOS version (e.g. <literal>16.03.1160.f2d4ee1</literal>).";
    };

    osRelease = mkOption {
      readOnly = true;
      type = types.str;
      default = fileContents releaseFile;
      description = "The vpsAdminOS release (e.g. <literal>16.03</literal>).";
    };

    osVersionSuffix = mkOption {
      internal = true;
      type = types.str;
      default = if pathExists suffixFile then fileContents suffixFile else "pre-git";
      description = "The vpsAdminOS version suffix (e.g. <literal>1160.f2d4ee1</literal>).";
    };

    osRevision = mkOption {
      internal = true;
      type = types.str;
      default = if pathIsDirectory gitRepo then commitIdFromGitRepo gitRepo
                else if pathExists revisionFile then fileContents revisionFile
                else "master";
      description = "The Git revision from which this vpsAdminOS configuration was built.";
    };

    nixpkgsRevision = mkOption {
      internal = true;
      type = types.str;
      default = if pathIsDirectory nixpkgsRepo then lib.substring 0 7 (commitIdFromGitRepo nixpkgsRepo)
                else "master";
      description = "The nixpkgs Git revision from which this vpsAdminOS configuration was built.";
    };

    osCodeName = mkOption {
      readOnly = true;
      type = types.str;
      description = "The vpsAdminOS release code name (e.g. <literal>Emu</literal>).";
    };

    defaultChannel = mkOption {
      internal = true;
      type = types.str;
      default = https://os.org/channels/os-unstable;
      description = "Default vpsAdminOS channel to which the root user is subscribed.";
    };

  };

  config = {

    system = {
      # These defaults are set here rather than up there so that
      # changing them would not rebuild the manual
      osLabel   = mkDefault cfg.osVersion;
      osVersion = mkDefault (cfg.osRelease + cfg.osVersionSuffix);
      osRevision      = mkIf (pathIsDirectory gitRepo) (mkDefault            gitCommitId);
      osVersionSuffix = mkIf (pathIsDirectory gitRepo) (mkDefault (".git." + gitCommitId));

      # Note: code names must only increase in alphabetical order.
      osCodeName = "About Time";
    };

    # Generate /etc/os-release.  See
    # https://www.freedesktop.org/software/systemd/man/os-release.html for the
    # format.
    environment.etc."os-release".text =
      ''
        NAME=vpsAdminOS
        ID=vpsadminos
        VERSION="${config.system.osVersion} (${config.system.osCodeName})"
        VERSION_CODENAME=${toLower config.system.osCodeName}
        VERSION_ID="${config.system.osVersion}"
        NIXPKGS_VERSION="${config.system.nixpkgsRevision}"
        PRETTY_NAME="vpsAdminOS ${config.system.osVersion} (${config.system.osCodeName})"
        HOME_URL="https://vpsadminos.org/"
        #SUPPORT_URL="https://vpsadminos.org/support.html"
        BUG_REPORT_URL="https://github.com/vpsfreecz/vpsdaminos/issues"
      '';

  };

}
