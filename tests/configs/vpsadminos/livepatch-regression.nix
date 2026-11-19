args@{
  config,
  lib,
  pkgs,
  ...
}:

let
  livepatchRegressionTest = args.livepatchRegressionTest or null;
  planPath =
    if livepatchRegressionTest == null then builtins.getEnv "VPSADMINOS_LIVEPATCH_PLAN" else null;
  capturePath =
    if livepatchRegressionTest == null then builtins.getEnv "VPSADMINOS_LIVEPATCH_CAPTURE" else null;
  setId =
    if livepatchRegressionTest == null then
      builtins.getEnv "VPSADMINOS_LIVEPATCH_SET_ID"
    else
      livepatchRegressionTest.setId;
  plan =
    if livepatchRegressionTest == null then
      builtins.fromJSON (builtins.readFile planPath)
    else
      livepatchRegressionTest.plan;
  capture =
    if livepatchRegressionTest == null then
      builtins.fromJSON (builtins.readFile capturePath)
    else
      livepatchRegressionTest.capture;
  runtimeRoot = if livepatchRegressionTest == null then "" else livepatchRegressionTest.runtimeRoot;
  runtimePath = path: "${runtimeRoot}${path}";
  uname =
    if livepatchRegressionTest == null then
      "${pkgs.coreutils}/bin/uname"
    else
      livepatchRegressionTest.uname;
  manager =
    if livepatchRegressionTest == null then
      "${config.system.build.livePatchManager}/bin/live-patches"
    else
      livepatchRegressionTest.manager;
  matchingSets = builtins.filter (candidate: candidate.id == setId) plan.sets;
  matchingCapturedSets = builtins.filter (candidate: candidate.id == setId) capture.sets;
  qualificationSet = builtins.head matchingSets;
  capturedSet = builtins.head matchingCapturedSets;
  plannedMembers = qualificationSet.members;
  capturedMembers = capturedSet.members;
  plannedReleases = map (member: member.release) plannedMembers;
  capturedReleases = map (member: member.release) capturedMembers;
  kernelMatches = config.boot.kernelVersion == qualificationSet.kernelVersion;
  configuredModules = config.system.build.livePatchModules;
  configuredReleases = builtins.attrNames configuredModules;
  sameSortedStrings =
    left: right: lib.sort builtins.lessThan left == lib.sort builtins.lessThan right;
  isNonEmptyString = value: builtins.isString value && value != "";
  allSameNonEmptyString =
    values:
    values != [ ]
    && lib.all isNonEmptyString values
    && lib.all (value: value == builtins.head values) values;
  capturedTargetIds = map (member: member.identity.targetId or null) capturedMembers;
  capturedTargetValidation =
    assert livepatchRegressionTest != null || allSameNonEmptyString capturedTargetIds;
    true;
  capturedTargetId =
    if livepatchRegressionTest != null then null else builtins.head capturedTargetIds;
  configuredTargetIds = map (
    release: configuredModules.${release}.kernelTarget.id or null
  ) plannedReleases;
  releaseValidation =
    assert !kernelMatches || sameSortedStrings configuredReleases plannedReleases;
    true;
  configuredTargetValidation =
    assert
      livepatchRegressionTest != null || !kernelMatches || allSameNonEmptyString configuredTargetIds;
    true;
  targetMatches =
    livepatchRegressionTest != null || builtins.head configuredTargetIds == capturedTargetId;
  targetEligible = kernelMatches && releaseValidation && configuredTargetValidation && targetMatches;
  moduleMatchesCapture =
    index:
    let
      planned = builtins.elemAt plannedMembers index;
      captured = builtins.elemAt capturedMembers index;
      configured = configuredModules.${planned.release};
    in
    captured.release == planned.release
    && captured.identity.sourceRevision == plan.sourceRevision
    && captured.identity.producer == toString configured
    && captured.identity.module == "${configured}/${configured.batch.installPath}"
    && captured.identity.moduleName == configured.batch.moduleName;
  membersMatch = lib.all moduleMatchesCapture (lib.range 0 (builtins.length plannedMembers - 1));
  memberValidation =
    assert !targetEligible || membersMatch;
    true;
  configValidation = releaseValidation && configuredTargetValidation && memberValidation;
  validatedTargetEligible = targetEligible && memberValidation;
  expectedInventory = pkgs.writeText "livepatch-regression-inventory-${setId}" (
    lib.concatMapStringsSep "\n" (
      index:
      let
        planned = builtins.elemAt plannedMembers index;
        captured = builtins.elemAt capturedMembers index;
      in
      "ordinal=${toString planned.releaseOrdinal} release=${planned.release} "
      + "module=${captured.identity.moduleName} configured=yes present=yes enabled=1 "
      + "transition=0 replace=0 state=active"
    ) (lib.range 0 (builtins.length plannedMembers - 1))
    + "\n"
  );
  admission = {
    schemaVersion = 1;
    inherit setId;
    sourceRevision = plan.sourceRevision;
    system = plan.system;
    kernelVersion = qualificationSet.kernelVersion;
    tipRelease = qualificationSet.tipRelease;
    plan = {
      id = qualificationSet.id;
      members = plannedMembers;
    };
    captured = {
      id = capturedSet.id;
      members = capturedMembers;
    };
  };
  gate = pkgs.writeShellScript "livepatch-regression-gate-${setId}" ''
    set -euo pipefail

    marker=${lib.escapeShellArg (runtimePath "/run/livepatch-regression/verified")}
    ${pkgs.coreutils}/bin/rm -f -- "$marker"
    ${pkgs.coreutils}/bin/mkdir -p -- ${lib.escapeShellArg (runtimePath "/run/livepatch-regression")}

    fail() {
      printf 'livepatch regression gate: %s\n' "$*" >&2
      exit 1
    }

    observed_release=$(${uname} -r) || fail 'cannot read uname release'
    [[ "$observed_release" == ${lib.escapeShellArg qualificationSet.tipRelease} ]] ||
      fail "uname release $observed_release does not match ${qualificationSet.tipRelease}"
    [[ -d ${lib.escapeShellArg (runtimePath "/run/booted-system/kernel-modules/lib/modules/${qualificationSet.kernelVersion}")} ]] ||
      fail 'booted native kernel module tree is missing'

    ${lib.concatMapStringsSep "\n" (
      captured:
      let
        identity = captured.identity;
      in
      ''
        [[ "$(${pkgs.findutils}/bin/find ${lib.escapeShellArg (runtimePath "/sys/module")} -mindepth 1 -maxdepth 1 -type d -name ${lib.escapeShellArg identity.moduleName} -printf . | ${pkgs.coreutils}/bin/wc -c)" == 1 ]] ||
          fail ${lib.escapeShellArg "kernel module ${identity.moduleName} is not present exactly once"}
        [[ "$(${pkgs.findutils}/bin/find ${lib.escapeShellArg (runtimePath "/sys/kernel/livepatch")} -mindepth 1 -maxdepth 1 -type d -name ${lib.escapeShellArg identity.moduleName} -printf . | ${pkgs.coreutils}/bin/wc -c)" == 1 ]] ||
          fail ${lib.escapeShellArg "livepatch ${identity.moduleName} is not present exactly once"}
        [[ "$(${pkgs.coreutils}/bin/cat ${lib.escapeShellArg (runtimePath "/sys/kernel/livepatch/${identity.moduleName}/enabled")})" == 1 ]] ||
          fail ${lib.escapeShellArg "livepatch ${identity.moduleName} is not enabled"}
        [[ "$(${pkgs.coreutils}/bin/cat ${lib.escapeShellArg (runtimePath "/sys/kernel/livepatch/${identity.moduleName}/transition")})" == 0 ]] ||
          fail ${lib.escapeShellArg "livepatch ${identity.moduleName} is still transitioning"}
        [[ "$(${pkgs.coreutils}/bin/cat ${lib.escapeShellArg (runtimePath "/sys/kernel/livepatch/${identity.moduleName}/replace")})" == 0 ]] ||
          fail ${lib.escapeShellArg "livepatch ${identity.moduleName} unexpectedly requests replace"}
        [[ "$(${pkgs.coreutils}/bin/sha256sum ${lib.escapeShellArg identity.module} | ${pkgs.coreutils}/bin/cut -d' ' -f1)" == ${lib.escapeShellArg identity.moduleSha256} ]] ||
          fail ${lib.escapeShellArg "captured module bytes changed for ${identity.moduleName}"}
      ''
    ) capturedMembers}

    inventory=$(${manager} status) ||
      fail 'production manager inventory failed'
    printf '%s\n' "$inventory" > ${lib.escapeShellArg (runtimePath "/run/livepatch-regression/inventory.actual")}
    ${pkgs.diffutils}/bin/cmp -s ${expectedInventory} ${lib.escapeShellArg (runtimePath "/run/livepatch-regression/inventory.actual")} ||
      fail 'production manager inventory does not equal the captured stack'

    ${pkgs.coreutils}/bin/install ${
      lib.optionalString (livepatchRegressionTest == null) "-o 0 -g 0 "
    }-m 0400 /dev/null "$marker"
  '';
in
assert livepatchRegressionTest != null || planPath != "";
assert livepatchRegressionTest != null || capturePath != "";
assert setId != "";
assert plan.schemaVersion == 1;
assert capture.schemaVersion == 1;
assert capture.sourceRevision == plan.sourceRevision;
assert builtins.length matchingSets == 1;
assert builtins.length matchingCapturedSets == 1;
assert plannedMembers != [ ];
assert builtins.length plannedMembers == builtins.length capturedMembers;
assert plannedReleases == capturedReleases;
assert capturedTargetValidation;
assert livepatchRegressionTest == null || configValidation;
lib.mkMerge [
  {
    # A deliberate test-level mkForce still wins and makes the evaluated
    # sentinel false, so the metadata partition can report that script as a
    # configuration bypass instead of silently changing its purpose.
    boot.kernelVersion = lib.mkOverride 60 qualificationSet.kernelVersion;

    environment.etc."livepatch-regression/admission.json".text = builtins.toJSON admission;
  }

  (lib.mkIf validatedTargetEligible {
    environment.etc = {
      "livepatch-regression/sentinel".text = setId;
      "livepatch-regression/expected-inventory".source = expectedInventory;
      "livepatch-regression/gate".source = gate;
    };

    # The production manager appends its automatic loader earlier at the same
    # option boundary. This gate must run afterwards and before stage 2 execs
    # runit, which is when any test shell could announce readiness.
    boot.postBootCommands = lib.mkAfter ''
      refusal=/run/livepatch-regression/refusal
      ${pkgs.coreutils}/bin/rm -f -- "$refusal"
      if ! gate_output=$(${gate} 2>&1); then
        ${pkgs.coreutils}/bin/mkdir -p -- /run/livepatch-regression
        printf '%s\n' "$gate_output" | ${pkgs.coreutils}/bin/tee "$refusal" >&2
        echo 'livepatch regression gate refused the boot; forcing guest reboot' >&2
        reboot -f
        while :; do
          ${pkgs.coreutils}/bin/sleep 3600
        done
      fi
    '';
  })

  (lib.mkIf kernelMatches {
    services.live-patches = {
      enable = lib.mkOverride 60 true;
      loadOnBoot = lib.mkOverride 60 targetEligible;
      loadOnSwitch = lib.mkOverride 60 false;
    };
  })
]
