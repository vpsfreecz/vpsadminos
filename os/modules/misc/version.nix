{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.system.vpsadminos;
  opt = config.system.vpsadminos;
  kernel = config.boot.kernelPackages.kernel;
  kernelDefinitions = import ../../packages/linux/available-kernels.nix { inherit lib; };

  # Node-preflight (P-20): whether this image is a cred-guard *test* build.
  # A serving node must not be one; the record and the warning below make
  # that visible.
  credGuardTest = (import ../../packages/linux/cred-guard-test-selectors.nix).requested;

  versionFile = ../../../.version;
  suffixFile = ../../../.version-suffix;
  revisionFile = ../../../.git-revision;
  gitRepo = "${toString ../../..}/.git";
  gitCommitId = lib.substring 0 7 (commitIdFromGitRepo gitRepo);
  sourceRevision = if pathIsDirectory gitRepo then commitIdFromGitRepo gitRepo else cfg.revision;

  inherit (lib)
    concatStringsSep
    mapAttrsToList
    toLower
    literalExpression
    mkRenamedOptionModule
    mkDefault
    mkOption
    mkIf
    trivial
    types
    commitIdFromGitRepo
    fileContents
    pathExists
    pathIsDirectory
    ;

  needsEscaping = s: null != builtins.match "[a-zA-Z0-9]+" s;
  escapeIfNecessary = s: if needsEscaping s then s else ''"${lib.escape [ "\$" "\"" "\\" "\`" ] s}"'';
  attrsToText =
    attrs:
    concatStringsSep "\n" (mapAttrsToList (n: v: "${n}=${escapeIfNecessary (toString v)}") attrs)
    + "\n";

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
    SUPPORT_URL = lib.optionalString (
      cfg.distroId == "vpsadminos"
    ) "https://github.com/vpsfreecz/vpsadminos";
    BUG_REPORT_URL = lib.optionalString (
      cfg.distroId == "vpsadminos"
    ) "https://github.com/vpsfreecz/vpsadminos/issues";
    SUPPORT_END = "2023-12-31";
  }
  // lib.optionalAttrs (cfg.variant_id != null) {
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
      default =
        if pathIsDirectory gitRepo then
          commitIdFromGitRepo gitRepo
        else if pathExists revisionFile then
          fileContents revisionFile
        else
          null;
      description = lib.mdDoc "The Git revision from which this vpsAdminOS configuration was built.";
    };

    vpsadminos.revisionDirty = mkOption {
      internal = true;
      type = types.bool;
      default = pathIsDirectory gitRepo;
      description = lib.mdDoc ''
        Whether the vpsAdminOS source contained changes outside of the reported
        Git revision. Direct builds from a Git checkout are conservatively
        considered dirty unless their caller supplies exact source metadata.
      '';
    };

    vpsadminos.nixpkgsVersion = mkOption {
      internal = true;
      type = types.str;
      default = lib.version;
      description = lib.mdDoc "The nixpkgs version used to build this vpsAdminOS configuration.";
    };

    vpsadminos.nixpkgsRevision = mkOption {
      internal = true;
      type = types.nullOr types.str;
      default = null;
      description = lib.mdDoc "The exact nixpkgs revision used to build this vpsAdminOS configuration.";
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

    vpsadminos.enableUnstable = mkOption {
      type = types.bool;
      default = false;
      description = lib.mdDoc "Enables unstable vpsAdminOS features and components (unstable kernel especially)";
    };

    vpsadminos.zfsDebug = mkOption {
      type = types.bool;
      default = false;
      description = lib.mdDoc "Enables OpenZFS debug build";
    };

    vpsadminos.rubyCrashReportTemplate = mkOption {
      type = types.nullOr types.str;
      default = "/var/log/crash-reports/%f-crash-%p-%t.log";
      example = "/var/log/crash-reports/%f-crash-%p-%t.log";
      description = lib.mdDoc ''
        Template exported as `RUBY_CRASH_REPORT` by selected vpsAdminOS Ruby
        daemons.

        This keeps Ruby fatal crash reports out of service logs by default and
        stores them in per-crash files under `/var/log/crash-reports`. Set to
        `/dev/null` to discard crash reports or to `null` to let Ruby write
        them to stderr.
      '';
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
      default = "https://github.com/vpsfreecz/vpsadminos/archive/refs/heads/staging.tar.gz";
      description = "Default vpsAdminOS channel to which the root user is subscribed.";
    };

  };

  config = {
    # Node-preflight (P-20) warnings: each is a containment precondition that
    # must hold on a node running tenant workloads; the evidence record above
    # carries the same facts to the fleet.  Warnings, not assertions: swap and
    # debugfs are opt-in, so making them unbuildable would be an operator
    # decision, while the checklist's failure action is the fleet record.
    warnings = lib.optionals credGuardTest [
      "containment: this image is a cred-guard test build (P-20/P1) — it must not run tenant workloads."
    ] ++ lib.optional (builtins.length config.swapDevices != 0)
      "containment: swapDevices is not empty (P-20/P3) — swap must be off on nodes running tenant workloads."
    ++ lib.optional (builtins.any
      (p: (lib.hasPrefix "resume=" p) || (lib.hasPrefix "resume_offset=" p))
      config.boot.kernelParams)
      "containment: a hibernation resume point is configured (P-20/P4)."
    ++ lib.optional (builtins.any
      (fs: (fs.fsType or "") == "debugfs")
      (builtins.attrValues config.fileSystems))
      "containment: debugfs is configured as a filesystem (P-20/P10) — keep it off tenant-reachable paths.";

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
      # nodectld reads this through /run/booted-system/etc, not /etc.  The
      # latter follows the most recently activated closure and may describe a
      # kernel which has not been booted yet.
      "vpsadminos/security-evidence.json".text = builtins.toJSON {
        schemaVersion = 1;
        version = cfg.version;
        revision = sourceRevision;
        revisionDirty = cfg.revisionDirty;
        nixpkgsVersion = cfg.nixpkgsVersion;
        nixpkgsRevision = cfg.nixpkgsRevision;
        kernelVersion = config.boot.kernelVersion;
        kernelModDirVersion = kernel.modDirVersion;
        kernelSourceRevision = kernelDefinitions.kernels.${config.boot.kernelVersion}.rev or null;
        kernelConfig = toString kernel.configfile;
        sysctls = config.boot.kernel.sysctl;
        # Containment preconditions (container-hardening preflight P1/P3):
        # the fleet record must show whether swap is configured and what the
        # boot command line carries (e.g. auth_guard=off/log must be visible).
        containment = {
          swapDeviceCount = builtins.length config.swapDevices;
          kernelParams = config.boot.kernelParams;
          # Node-preflight (P-20) record: the enforceable node-side facts the
          # containment checklist asks the fleet record to carry, so a node
          # failing P3/P4/P10 (or one that is a test build) is visible without
          # reading the generated configuration by hand.
          debugfsConfigured = builtins.any
            (fs: (fs.fsType or "") == "debugfs")
            (builtins.attrValues config.fileSystems);
          resumeConfigured = builtins.any
            (p: (lib.hasPrefix "resume=" p) || (lib.hasPrefix "resume_offset=" p))
            config.boot.kernelParams;
          authGuardTestBuild = credGuardTest;
        };
      };
    };

    boot.postBootCommands = ''
      mkdir -p /var/log/crash-reports
      chmod 0700 /var/log/crash-reports
      echo "vpsAdminOS ${cfg.version} with kernel ${config.boot.kernelVersion}" > /dev/kmsg
    '' + ''
      # Containment preflight (P-20, node side, no kernel code): record the
      # enforceable facts at boot under a stable prefix so the responder and
      # the fleet record can key on them.  Observation only — nothing here
      # changes enforcement or fails the boot.
      containment_swap=$(awk 'END { print (NR > 1) ? NR - 1 : 0 }' /proc/swaps 2>/dev/null || echo unknown)
      containment_resume=$(tr ' ' '\n' < /proc/cmdline 2>/dev/null | grep -cE '^(resume|resume_offset)=' || true)
      containment_auth_test=$(zcat /proc/config.gz 2>/dev/null | grep -m1 '^CONFIG_AUTH_GUARD_TEST=' | cut -d= -f2 || echo unknown)
      containment_sig_force=$(zcat /proc/config.gz 2>/dev/null | grep -m1 '^CONFIG_MODULE_SIG_FORCE=' | cut -d= -f2 || echo unknown)
      echo "containment-preflight: swap_devices=$containment_swap resume_params=$containment_resume auth_guard_test=$containment_auth_test module_sig_force=$containment_sig_force" > /dev/kmsg
      printf '{"schemaVersion":1,"swapDevices":%s,"resumeParams":%s,"authGuardTest":%s,"moduleSigForce":%s}\n' \
        "$containment_swap" "$containment_resume" "$containment_auth_test" "$containment_sig_force" \
        > /run/containment-preflight.json 2>/dev/null || true
    '';

  };

  # uses version info nixpkgs, which requires a full nixpkgs path
  meta.buildDocsInSandbox = false;

}
