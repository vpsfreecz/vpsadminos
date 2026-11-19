{
  affectedPlan ? null,
  capture ? null,
  configuration ? null,
  event ? null,
  flake ? null,
  plan ? null,
  reference ? null,
  root ? null,
  sourceRevision ? null,
  system ? "x86_64-linux",
}:

let
  lib = if flake == null then null else flake.inputs.nixpkgs.lib;
  evaluated =
    if reference != null then
      null
    else
      flake.lib.vpsadminosSystem {
        inherit system configuration;
        modules = [
          (root + "/os/configs/qemu.nix")
          (root + "/tests/configs/vpsadminos/base.nix")
        ];
      };
  cfg = if evaluated == null then null else evaluated.config.services.live-patches;
  configuredModules =
    if evaluated == null then { } else evaluated.config.system.build.livePatchModules or { };
  releases =
    if evaluated == null then
      [ ]
    else
      lib.sort (
        left: right:
        configuredModules.${left}.batch.releaseOrdinal < configuredModules.${right}.batch.releaseOrdinal
      ) (builtins.attrNames configuredModules);
  members =
    if evaluated == null then
      [ ]
    else
      map (
        release:
        let
          module = configuredModules.${release};
        in
        {
          inherit release;
          targetId = module.kernelTarget.id;
          producer = toString module;
          module = "${module}/${module.batch.installPath}";
          moduleName = module.batch.moduleName;
        }
      ) releases;
  targetIds = if evaluated == null then [ ] else lib.unique (map (member: member.targetId) members);
  normal =
    if reference != null then
      reference
    else
      assert members == [ ] || builtins.length targetIds == 1;
      {
        schemaVersion = 1;
        sourceRevision =
          if sourceRevision == null then evaluated.config.system.vpsadminos.revision else sourceRevision;
        flakeLockSha256 = builtins.hashFile "sha256" (root + "/flake.lock");
        kernelVersion = evaluated.config.boot.kernelVersion;
        automaticLoad = {
          enable = cfg.enable;
          loadOnBoot = cfg.loadOnBoot;
        };
        targetId = if targetIds == [ ] then null else builtins.head targetIds;
        inherit members system;
      };
  hasDecisionInputs = plan != null && affectedPlan != null && capture != null && event != null;
  capturedTuple =
    set:
    let
      matching = builtins.filter (candidate: candidate.id == set.id) capture.sets;
      capturedSet =
        assert builtins.length matching == 1;
        builtins.head matching;
      capturedTargetIds = lib.unique (map (member: member.identity.targetId) capturedSet.members);
    in
    assert builtins.length capturedTargetIds == 1;
    {
      sourceRevision = capture.sourceRevision;
      flakeLockSha256 = capture.flakeLockSha256;
      kernelVersion = set.kernelVersion;
      targetId = builtins.head capturedTargetIds;
      members = map (member: {
        inherit (member) release;
        inherit (member.identity)
          module
          moduleName
          producer
          targetId
          ;
      }) capturedSet.members;
    };
  decision =
    set:
    let
      matchingPlanSets = builtins.filter (candidate: candidate.id == set.id) plan.sets;
      canonicalSet =
        assert builtins.length matchingPlanSets == 1;
        builtins.head matchingPlanSets;
      captured = capturedTuple set;
      covered =
        event == "push"
        && normal.automaticLoad.enable
        && normal.automaticLoad.loadOnBoot
        && normal.sourceRevision == captured.sourceRevision
        && normal.flakeLockSha256 == captured.flakeLockSha256
        && normal.kernelVersion == captured.kernelVersion
        && normal.targetId == captured.targetId
        && normal.members == captured.members;
    in
    assert canonicalSet == set;
    {
      setId = set.id;
      inherit (set) kernelVersion tipRelease;
      memberCount = builtins.length set.members;
      coveredByNormalCi = covered;
      inherit captured;
    };
  decisions = if hasDecisionInputs then map decision affectedPlan.sets else [ ];
in
assert !hasDecisionInputs || normal.sourceRevision != null;
{
  schemaVersion = 1;
  inherit normal;
}
// lib.optionalAttrs hasDecisionInputs {
  inherit decisions event;
  workloadMatrix.include = map (item: {
    inherit (item)
      kernelVersion
      memberCount
      setId
      tipRelease
      ;
  }) (builtins.filter (item: !item.coveredByNormalCi) decisions);
}
