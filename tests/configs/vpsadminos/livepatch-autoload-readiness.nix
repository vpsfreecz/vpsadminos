args@{
  config,
  lib,
  pkgs,
  ...
}:

let
  test = args.livepatchAutoloadReadinessTest or null;
  cfg = config.services.live-patches;
  configuredModules = config.system.build.livePatchModules or { };
  configuredReleases = lib.sort (
    left: right:
    configuredModules.${left}.batch.releaseOrdinal < configuredModules.${right}.batch.releaseOrdinal
  ) (builtins.attrNames configuredModules);
  readinessEnabled = cfg.enable && cfg.loadOnBoot && configuredReleases != [ ];
  tipRelease = if configuredReleases == [ ] then "" else lib.last configuredReleases;
  runtimeRoot = if test == null then "" else test.runtimeRoot;
  runtimePath = path: "${runtimeRoot}${path}";
  uname = if test == null then "${pkgs.coreutils}/bin/uname" else test.uname;
  manager =
    if test == null then "${config.system.build.livePatchManager}/bin/live-patches" else test.manager;
  expectedInventory = pkgs.writeText "livepatch-autoload-readiness-inventory" (
    lib.concatMapStringsSep "\n" (
      release:
      let
        module = configuredModules.${release};
      in
      "ordinal=${toString module.batch.releaseOrdinal} release=${release} "
      + "module=${module.batch.moduleName} configured=yes present=yes enabled=1 "
      + "transition=0 replace=0 state=active"
    ) configuredReleases
    + "\n"
  );
  gate = pkgs.writeShellScript "livepatch-autoload-readiness-gate" ''
    set -euo pipefail

    runtime=${lib.escapeShellArg (runtimePath "/run/livepatch-autoload-readiness")}
    marker="$runtime/verified"
    refusal="$runtime/refusal"
    ${pkgs.coreutils}/bin/rm -f -- "$marker" "$refusal"
    ${pkgs.coreutils}/bin/mkdir -p -- "$runtime"

    fail() {
      printf 'livepatch automatic-load readiness: %s\n' "$*" >&2
      exit 1
    }

    observed_release=$(${uname} -r) ||
      fail 'cannot read uname release'
    [[ "$observed_release" == ${lib.escapeShellArg tipRelease} ]] ||
      fail "uname release $observed_release does not match ${tipRelease}"

    inventory=$(${manager} status) ||
      fail 'production manager inventory failed'
    printf '%s\n' "$inventory" > "$runtime/inventory.actual"
    ${pkgs.diffutils}/bin/cmp -s ${expectedInventory} "$runtime/inventory.actual" ||
      fail 'production manager inventory does not equal the configured stack'

    ${pkgs.coreutils}/bin/install ${lib.optionalString (test == null) "-o 0 -g 0"} \
      -m 0400 /dev/null "$marker"
  '';
in
lib.mkIf readinessEnabled (
  {
    # The production manager appends its automatic loader first. This assertion
    # runs afterwards and must not return to stage 2 when loading was incomplete.
    boot.postBootCommands = lib.mkAfter ''
      if ! gate_output=$(${gate} 2>&1); then
        ${pkgs.coreutils}/bin/mkdir -p -- /run/livepatch-autoload-readiness
        printf '%s\n' "$gate_output" |
          ${pkgs.coreutils}/bin/tee /run/livepatch-autoload-readiness/refusal >&2
        echo 'livepatch automatic-load readiness refused the boot; forcing guest reboot' >&2
        reboot -f
        while :; do
          ${pkgs.coreutils}/bin/sleep 3600
        done
      fi
    '';
  }
  // lib.optionalAttrs (test != null) {
    environment.etc."livepatch-autoload-readiness/gate".source = gate;
  }
)
