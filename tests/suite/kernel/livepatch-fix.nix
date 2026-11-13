import ../../make-template.nix (
  { row }:
  let
    planPath = builtins.getEnv "VPSADMINOS_LIVEPATCH_PLAN";
    capturePath = builtins.getEnv "VPSADMINOS_LIVEPATCH_CAPTURE";
    plan = builtins.fromJSON (builtins.readFile planPath);
    capture = builtins.fromJSON (builtins.readFile capturePath);
    sets = builtins.filter (candidate: candidate.id == row.setId) plan.sets;
    set = builtins.head sets;
    selected = builtins.filter (oracle: builtins.elem oracle.id row.oracleIds) set.oracles;
  in
  assert planPath != "";
  assert capturePath != "";
  assert builtins.length sets == 1;
  assert builtins.length selected == builtins.length row.oracleIds;
  {
    instance = row.rowId;

    test =
      { pkgs }:
      let
        lib = pkgs.lib;
        repositoryRoot = ../../..;
        adapters = map (
          oracle:
          let
            adapterPath = repositoryRoot + "/${oracle.testAdapter}";
            adapter = import adapterPath {
              inherit
                capture
                oracle
                plan
                pkgs
                row
                ;
              qualificationSet = set;
            };
          in
          assert lib.hasPrefix "os/livepatches/batches/" oracle.testAdapter;
          assert lib.hasInfix "/qualification/helpers/" oracle.testAdapter;
          assert lib.hasSuffix ".nix" oracle.testAdapter;
          assert builtins.isList (adapter.modules or [ ]);
          assert builtins.isAttrs (adapter.oracleScripts or null);
          assert builtins.hasAttr oracle.role adapter.oracleScripts;
          assert builtins.isString adapter.oracleScripts.${oracle.role};
          {
            inherit oracle;
            modules = adapter.modules or [ ];
            script = adapter.oracleScripts.${oracle.role};
          }
        ) selected;
      in
      {
        name = "kernel-livepatch-fix-${row.rowId}";
        description = "Declared livepatch fix oracle ${row.profileId}";
        tags = [ row.runnerClass ];
        labels = {
          livepatch-profile = row.profileId;
          livepatch-set = row.setId;
        };

        machine = import ../../machines/vpsadminos/with-empty.nix {
          inherit pkgs;
          config = {
            imports = [
              ../../configs/vpsadminos/livepatch.nix
            ]
            ++ lib.concatMap (adapter: adapter.modules) adapters;
          };
        };

        testScript = ''
          require 'json'

          ROW = ${builtins.toJSON row}
          ORACLE_SCRIPTS = ${
            builtins.toJSON (
              builtins.listToAttrs (
                map (adapter: {
                  name = adapter.oracle.id;
                  value = adapter.script;
                }) adapters
              )
            )
          }

          before(:suite) do
            machine.start
            machine.wait_until_online
            @plan = JSON.parse(machine.succeeds('cat /etc/livepatch-qualification/plan.json')[1])
            @capture = JSON.parse(machine.succeeds('cat /etc/livepatch-qualification/capture.json')[1])
          end

          describe 'declared fix-local oracle', order: :defined do
            it 'runs only the exact selected oracle shard' do
              expect(ORACLE_SCRIPTS.keys.sort).to eq(ROW.fetch('oracleIds').sort)
              ROW.fetch('oracleIds').each do |oracle_id|
                instance_eval(ORACLE_SCRIPTS.fetch(oracle_id), "oracle #{oracle_id}")
              end
            end
          end
        '';
      };
  }
)
