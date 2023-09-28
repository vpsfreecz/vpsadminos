{ config, lib, pkgs, ... }:

let
  cfg = config.system.vpsadminos;
  opt = config.system.vpsadminos;

  versionFile  = ../../../.version;
  suffixFile   = ../../../.version-suffix;
  revisionFile = ../../../.git-revision;
  gitRepo      = "${toString ../../..}/.git";
  gitCommitId  = lib.substring 0 7 (commitIdFromGitRepo gitRepo);

  inherit (lib)
    concatStringsSep mapAttrsToList toLower
    literalExpression mkRenamedOptionModule mkDefault mkOption mkIf trivial types
    commitIdFromGitRepo fileContents pathExists pathIsDirectory;

  needsEscaping = s: null != builtins.match "[a-zA-Z0-9]+" s;
  escapeIfNecessary = s: if needsEscaping s then s else ''"${lib.escape [ "\$" "\"" "\\" "\`" ] s}"'';
  attrsToText = attrs:
    concatStringsSep "\n" (
      mapAttrsToList (n: v: ''${n}=${escapeIfNecessary (toString v)}'') attrs
    ) + "\n";

  osReleaseContents = {
    NAME = "${cfg.distroName}";
    ID = "${cfg.distroId}";
    VERSION = "${cfg.release} (${cfg.codeName})";
    VERSION_CODENAME = toLower cfg.codeName;
    VERSION_ID = cfg.release;
    BUILD_ID = cfg.version;
    PRETTY_NAME = "${cfg.distroName} ${cfg.release} (${cfg.codeName})";
    LOGO = "nix-snowflake";
    HOME_URL = lib.optionalString (cfg.distroId == "vpsadminos") "https://vpsadminos.org/";
    DOCUMENTATION_URL = lib.optionalString (cfg.distroId == "vpsadminos") "https://vpsadminos.org";
    SUPPORT_URL = lib.optionalString (cfg.distroId == "vpsadminos") "https://github.com/vpsfreecz/vpsadminos";
    BUG_REPORT_URL = lib.optionalString (cfg.distroId == "vpsadminos") "https://github.com/vpsfreecz/vpsadminos/issues";
    SUPPORT_END = "2023-12-31";
  } // lib.optionalAttrs (cfg.variant_id != null) {
    VARIANT_ID = cfg.variant_id;
  };

  initrdReleaseContents = osReleaseContents // {
    PRETTY_NAME = "${osReleaseContents.PRETTY_NAME} (Initrd)";
  };
  initrdRelease = pkgs.writeText "initrd-release" (attrsToText initrdReleaseContents);

in

{

  options.system = {

    vpsadminos.version = mkOption {
      internal = true;
      type = types.str;
      description = lib.mdDoc "The full vpsAdminOS version (e.g. `16.03.1160.f2d4ee1`).";
    };

    vpsadminos.release = mkOption {
      readOnly = true;
      type = types.str;
      default = fileContents versionFile;
      description = lib.mdDoc "The vpsAdminOS release (e.g. `16.03`).";
    };

    vpsadminos.versionSuffix = mkOption {
      internal = true;
      type = types.str;
      default = if pathExists suffixFile then fileContents suffixFile else "pre-git";
      description = lib.mdDoc "The vpsAdminOS version suffix (e.g. `1160.f2d4ee1`).";
    };

    vpsadminos.revision = mkOption {
      internal = true;
      type = types.nullOr types.str;
      default = if pathIsDirectory gitRepo then commitIdFromGitRepo gitRepo
                else if pathExists revisionFile then fileContents revisionFile
                else "staging";
      description = lib.mdDoc "The Git revision from which this vpsAdminOS configuration was built.";
    };

    vpsadminos.codeName = mkOption {
      readOnly = true;
      type = types.str;
      default = trivial.codeName;
      description = lib.mdDoc "The vpsAdminOS release code name (e.g. `Emu`).";
    };

    vpsadminos.distroId = mkOption {
      internal = true;
      type = types.str;
      default = "vpsadminos";
      description = lib.mdDoc "The id of the operating system";
    };

    vpsadminos.distroName = mkOption {
      internal = true;
      type = types.str;
      default = "vpsAdminOS";
      description = lib.mdDoc "The name of the operating system";
    };

    vpsadminos.variant_id = mkOption {
      type = types.nullOr (types.strMatching "^[a-z0-9._-]+$");
      default = null;
      description = lib.mdDoc "A lower-case string identifying a specific variant or edition of the operating system";
      example = "installer";
    };

    codeName = mkOption {
      readOnly = true;
      type = types.str;
      description = "The vpsAdminOS release code name (e.g. <literal>Emu</literal>).";
    };

    stateVersion = mkOption {
      type = types.str;
      default = cfg.release;
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

    defaultOsChannel = mkOption {
      internal = true;
      type = types.str;
      default = https://github.com/vpsfreecz/vpsadminos/archive/refs/heads/staging.tar.gz;
      description = "Default vpsAdminOS channel to which the root user is subscribed.";
    };

  };

  config = {

    system.vpsadminos = {
      # These defaults are set here rather than up there so that
      # changing them would not rebuild the manual
      version = mkDefault (cfg.release + cfg.versionSuffix);

      revision = mkIf (pathIsDirectory gitRepo) (mkDefault gitCommitId);

      versionSuffix = mkIf (pathIsDirectory gitRepo) (mkDefault (".git." + gitCommitId));
    };

    # Note: code names must only increase in alphabetical order.
    system.codeName = "Red Meat Steak";

    # Generate /etc/os-release.  See
    # https://www.freedesktop.org/software/systemd/man/os-release.html for the
    # format.
    environment.etc = {
      "lsb-release".text = attrsToText {
        LSB_VERSION = "${cfg.release} (${cfg.codeName})";
        DISTRIB_ID = "${cfg.distroId}";
        DISTRIB_RELEASE = cfg.release;
        DISTRIB_CODENAME = toLower cfg.codeName;
        DISTRIB_DESCRIPTION = "${cfg.distroName} ${cfg.release} (${cfg.codeName})";
      };

      "os-release".text = attrsToText osReleaseContents;
    };

  };

  # uses version info nixpkgs, which requires a full nixpkgs path
  meta.buildDocsInSandbox = false;

}
