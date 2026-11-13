{
  lib,
  ...
}:

let
  planPath = builtins.getEnv "VPSADMINOS_LIVEPATCH_PLAN";
  capturePath = builtins.getEnv "VPSADMINOS_LIVEPATCH_CAPTURE";
  rowId = builtins.getEnv "VPSADMINOS_LIVEPATCH_ROW_ID";
  plan = builtins.fromJSON (builtins.readFile planPath);
  capture = builtins.fromJSON (builtins.readFile capturePath);
  rows = builtins.filter (row: row.rowId == rowId) plan.rows;
  row = builtins.head rows;
  sets = builtins.filter (set: set.id == row.setId) plan.sets;
  set = builtins.head sets;
  capturedSets = builtins.filter (candidate: candidate.id == set.id) capture.sets;
in
if planPath == "" then
  {
    services.live-patches.enable = true;
    runit.services.live-patches.run = lib.mkForce "sleep inf";
  }
else
  assert capturePath != "";
  assert rowId != "";
  assert plan.schemaVersion == 1;
  assert capture.schemaVersion == 1;
  assert builtins.length rows == 1;
  assert builtins.length sets == 1;
  assert builtins.length capturedSets == 1;
  assert builtins.length set.members == builtins.length (builtins.head capturedSets).members;
  {
    boot.kernelVersion = lib.mkForce set.kernelVersion;
    services.live-patches.enable = true;

    # Qualification owns activation order; boot autoload would hide the native
    # baseline and make failure/recovery rows ambiguous.
    runit.services.live-patches.run = lib.mkForce "sleep inf";

    environment.etc = {
      "livepatch-qualification/plan.json".source = builtins.path {
        path = planPath;
        name = "livepatch-qualification-plan.json";
      };
      "livepatch-qualification/capture.json".source = builtins.path {
        path = capturePath;
        name = "livepatch-qualification-capture.json";
      };
    };
  }
