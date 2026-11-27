{
  forAllSystems,
  livepatchCiTools,
  livepatchPackageName,
  mergeChecks,
  mkLivepatchContext,
  nixpkgs,
  root,
  testFramework,
}:
{
  checks = forAllSystems (
    system:
    let
      pkgs = import nixpkgs { inherit system; };
      stackManagerUnit = import (root + "/os/modules/services/livepatches/tests/default.nix") {
        inherit pkgs;
      };
      stackManagerRendered = import (root + "/tests/suite/kernel/livepatch-set.nix") {
        pkgs = nixpkgs.outPath;
        inherit system testFramework;
        templateArgs.row = {
          managerFixture = true;
          rowId = "production-manager-private-stack";
        };
      };
      stackManagerReceipt = pkgs.writeText "livepatch-stack-manager-render.json" (
        builtins.toJSON {
          instance = stackManagerRendered.instance;
          name = stackManagerRendered.config.name;
          machines = builtins.attrNames stackManagerRendered.config.machines;
          tags = stackManagerRendered.config.tags;
        }
      );
      qualificationPlanner = import (root + "/os/livepatches/qualification.nix") { lib = pkgs.lib; };
      qualificationTarget.kernelVersion = "6.12.113";
      qualificationProfiles = [
        "set/vendor-aged-transition"
        "set/vendor-busy-transition"
        "set/vendor-failure-recovery"
        "set/vendor-lifecycle"
      ];
      qualificationPlatforms = {
        amd.runnerClass = "amd-livepatch";
        intel.runnerClass = "intel-kvm";
      };
      qualificationProfileSettings."set/vendor-aged-transition" = {
        developmentDwellSeconds = 300;
        releaseDwellSeconds = 1800;
        selectedEvidenceClass = "development-short";
      };
      mkQualificationOracle = fixId: oracleId: {
        schemaVersion = 1;
        inherit fixId;
        oracles = [
          {
            id = oracleId;
            scope = "fix";
            role = "fixed-path";
            applicablePlatforms = [
              "amd"
              "intel"
            ];
            timeoutClass = "oracle";
            expectedOutcome = "success";
            testAdapter = "os/livepatches/batches/6.12.113/1/qualification/helpers/${fixId}.nix";
            validator = "os/livepatches/batches/6.12.113/1/qualification/validators/${fixId}.sh";
          }
        ];
      };
      mkQualificationEntry =
        ordinal: fixId: oracleId:
        let
          release = "6.12.113.${toString ordinal}";
        in
        {
          batch = {
            inherit release;
            kernelTarget.kernelVersion = "6.12.113";
            payloadRevision = 1;
            unameLevel.releaseOrdinal = ordinal;
            lineage.predecessorBatch =
              if ordinal == 1 then null else { release = "6.12.113.${toString (ordinal - 1)}"; };
            fixes = [ { id = fixId; } ];
            oracleIds = [ oracleId ];
          };
          qualification = {
            schemaVersion = 1;
            inherit release;
            requiredGenericProfiles = qualificationProfiles;
            platforms = qualificationPlatforms;
            profileSettings = qualificationProfileSettings;
            oracles = [ (mkQualificationOracle fixId oracleId) ];
          };
        };
      qualificationRoot = mkQualificationEntry 1 "fix-a" "oracle-a";
      qualificationSuccessor = mkQualificationEntry 2 "fix-b" "oracle-b";
      mkQualificationPlan =
        entries:
        qualificationPlanner {
          builder = { };
          catalog = [ ];
          target = qualificationTarget;
          normalizedReleases = entries;
          plan = true;
          producerAttrs = builtins.listToAttrs (
            map (entry: {
              name = entry.batch.release;
              value = livepatchPackageName entry.batch.release;
            }) entries
          );
          sourceRevision = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
          inherit system;
        };
      qualificationPlanOne = mkQualificationPlan [ qualificationRoot ];
      qualificationPlanTwo = mkQualificationPlan [
        qualificationRoot
        qualificationSuccessor
      ];
      withQualificationProfileSettings =
        entry: settings:
        entry
        // {
          qualification = entry.qualification // {
            profileSettings."set/vendor-aged-transition" = settings;
          };
        };
      qualificationReleaseSelection = mkQualificationPlan [
        (withQualificationProfileSettings qualificationRoot (
          qualificationProfileSettings."set/vendor-aged-transition"
          // {
            selectedEvidenceClass = "release";
          }
        ))
      ];
      qualificationWorkload = import (root + "/tests/suite/kernel/livepatch-set/workload.nix") {
        inherit pkgs;
      };
      qualificationWorkloadPackage = builtins.head (
        (builtins.head qualificationWorkload.modules).environment.systemPackages
      );
      mapQualificationOracle =
        transform: entry:
        entry
        // {
          qualification = entry.qualification // {
            oracles = map (
              manifest:
              manifest
              // {
                oracles = map transform manifest.oracles;
              }
            ) entry.qualification.oracles;
          };
        };
      qualificationEvaluationFails = value: !(builtins.tryEval (builtins.deepSeq value true)).success;
      qualificationMissingProfile = mkQualificationPlan [
        (
          qualificationRoot
          // {
            qualification = qualificationRoot.qualification // {
              requiredGenericProfiles = [ "set/vendor-lifecycle" ];
            };
          }
        )
      ];
      qualificationMissingAgedSettings = mkQualificationPlan [
        (
          qualificationRoot
          // {
            qualification = builtins.removeAttrs qualificationRoot.qualification [ "profileSettings" ];
          }
        )
      ];
      qualificationPartialAgedSettings = mkQualificationPlan [
        (withQualificationProfileSettings qualificationRoot (
          builtins.removeAttrs qualificationProfileSettings."set/vendor-aged-transition" [
            "releaseDwellSeconds"
          ]
        ))
      ];
      qualificationExtraAgedSettings = mkQualificationPlan [
        (withQualificationProfileSettings qualificationRoot (
          qualificationProfileSettings."set/vendor-aged-transition"
          // {
            unexpected = true;
          }
        ))
      ];
      qualificationUnknownAgedClass = mkQualificationPlan [
        (withQualificationProfileSettings qualificationRoot (
          qualificationProfileSettings."set/vendor-aged-transition"
          // {
            selectedEvidenceClass = "unknown";
          }
        ))
      ];
      qualificationNonIntegerAgedSettings = mkQualificationPlan [
        (withQualificationProfileSettings qualificationRoot (
          qualificationProfileSettings."set/vendor-aged-transition"
          // {
            developmentDwellSeconds = 300.5;
          }
        ))
      ];
      qualificationNonPositiveAgedSettings = mkQualificationPlan [
        (withQualificationProfileSettings qualificationRoot (
          qualificationProfileSettings."set/vendor-aged-transition"
          // {
            developmentDwellSeconds = 0;
          }
        ))
      ];
      qualificationNonIncreasingAgedSettings = mkQualificationPlan [
        (withQualificationProfileSettings qualificationRoot (
          qualificationProfileSettings."set/vendor-aged-transition"
          // {
            developmentDwellSeconds = 1800;
          }
        ))
      ];
      qualificationMissingOracle = mkQualificationPlan [
        (
          qualificationRoot
          // {
            qualification = qualificationRoot.qualification // {
              oracles = [ ];
            };
          }
        )
      ];
      qualificationDuplicateOracle = mkQualificationPlan [
        qualificationRoot
        (
          qualificationSuccessor
          // {
            batch = qualificationSuccessor.batch // {
              oracleIds = [ "oracle-a" ];
            };
            qualification = qualificationSuccessor.qualification // {
              oracles = [ (mkQualificationOracle "fix-b" "oracle-a") ];
            };
          }
        )
      ];
      qualificationAuthoredRunnerClass = mkQualificationPlan [
        (mapQualificationOracle (oracle: oracle // { runnerClass = "amd-livepatch"; }) qualificationRoot)
      ];
      qualificationFlatOraclePath = mkQualificationPlan [
        (mapQualificationOracle (
          oracle:
          oracle
          // {
            testAdapter = "os/livepatches/batches/6.12.113.1/qualification/helpers/fix-a.nix";
          }
        ) qualificationRoot)
      ];
      qualificationLeadingZeroOraclePath = mkQualificationPlan [
        (mapQualificationOracle (
          oracle:
          oracle
          // {
            validator = "os/livepatches/batches/6.12.113/01/qualification/validators/fix-a.sh";
          }
        ) qualificationRoot)
      ];
      qualificationMissingPlatformRunner = mkQualificationPlan [
        (
          qualificationRoot
          // {
            qualification = qualificationRoot.qualification // {
              platforms = qualificationPlatforms // {
                amd = { };
              };
            };
          }
        )
      ];
      qualificationEmptyPlatformRunner = mkQualificationPlan [
        (
          qualificationRoot
          // {
            qualification = qualificationRoot.qualification // {
              platforms = qualificationPlatforms // {
                amd.runnerClass = "";
              };
            };
          }
        )
      ];
      qualificationWrongPlatformRunner = mkQualificationPlan [
        (
          qualificationRoot
          // {
            qualification = qualificationRoot.qualification // {
              platforms = qualificationPlatforms // {
                amd.runnerClass = "intel-kvm";
              };
            };
          }
        )
      ];
      qualificationUnknownApplicablePlatform = mkQualificationPlan [
        (mapQualificationOracle (
          oracle:
          oracle
          // {
            applicablePlatforms = [
              "amd"
              "arm"
            ];
          }
        ) qualificationRoot)
      ];
      qualificationAbsentApplicablePlatform = mkQualificationPlan [
        (mapQualificationOracle (
          oracle: builtins.removeAttrs oracle [ "applicablePlatforms" ]
        ) qualificationRoot)
      ];
      qualificationDuplicateApplicablePlatform = mkQualificationPlan [
        (mapQualificationOracle (
          oracle:
          oracle
          // {
            applicablePlatforms = [
              "amd"
              "amd"
            ];
          }
        ) qualificationRoot)
      ];
      qualificationUnsupportedIntel = mkQualificationPlan [
        (
          qualificationRoot
          // {
            qualification = qualificationRoot.qualification // {
              platforms = qualificationPlatforms // {
                intel = qualificationPlatforms.intel // {
                  unsupportedReason = "Intel qualification runner unavailable";
                };
              };
            };
          }
        )
      ];
      qualificationOracleRows = builtins.filter (row: row.scope == "fix") qualificationPlanOne.rows;
      qualificationRootSet = builtins.head qualificationPlanOne.sets;
      qualificationRootRow = builtins.head (
        builtins.filter (row: row.scope == "set") qualificationPlanOne.rows
      );
      qualificationSuccessorSet = builtins.head qualificationPlanTwo.sets;
      qualificationFixRow = builtins.head qualificationOracleRows;
      qualificationRubyJson = import (root + "/tests/suite/kernel/livepatch-ruby-json.nix") {
        lib = pkgs.lib;
      };
      qualificationOracleScript = ''
        producer = shell(identity.fetch('producer'))
        module_path = shell(identity.fetch('module'))
        evidence = "#{producer}/share/vpsadminos-livepatch"
        expected_sha = "#{identity.fetch('moduleSha256')}"
        machine.succeeds("test -f #{module_path}")
        literal_quotes = %q("double" and 'single')
        literal_backslash = 'C:\\livepatch\\module'
        payload_lines = <<~'PAYLOAD'
          before
        VPSADMINOS_LIVEPATCH_JSON_END
          after
        PAYLOAD
      '';
      qualificationOracleScriptMap = builtins.listToAttrs [
        {
          name = qualificationFixRow.id;
          value = qualificationOracleScript;
        }
      ];
      qualificationOracleScriptFile = pkgs.writeText "livepatch-qualification-oracle.rb" (
        qualificationOracleScript
      );
      qualificationRootSetJsonFile = pkgs.writeText "livepatch-qualification-root-set.json" (
        builtins.toJSON qualificationRootSet
      );
      qualificationRootRowJsonFile = pkgs.writeText "livepatch-qualification-root-row.json" (
        builtins.toJSON qualificationRootRow
      );
      qualificationSuccessorSetJsonFile = pkgs.writeText "livepatch-qualification-successor-set.json" (
        builtins.toJSON qualificationSuccessorSet
      );
      qualificationFixRowJsonFile = pkgs.writeText "livepatch-qualification-fix-row.json" (
        builtins.toJSON qualificationFixRow
      );
      qualificationOracleScriptMapJsonFile = pkgs.writeText "livepatch-qualification-oracle-map.json" (
        builtins.toJSON qualificationOracleScriptMap
      );
      qualificationSerializationCheck = pkgs.writeText "livepatch-qualification-serialization.rb" ''
        require 'digest'
        require 'json'

        root_set = ${qualificationRubyJson qualificationRootSet}
        root_row = ${qualificationRubyJson qualificationRootRow}
        successor_set = ${qualificationRubyJson qualificationSuccessorSet}
        fix_row = ${qualificationRubyJson qualificationFixRow}
        oracle_scripts = ${qualificationRubyJson qualificationOracleScriptMap}

        raise 'root predecessor is not nil' unless root_set.fetch('members').fetch(0).fetch('predecessorRelease').nil?
        raise 'root set did not round-trip' unless JSON.generate(root_set) == File.binread(ARGV.fetch(1))
        raise 'root row did not round-trip' unless JSON.generate(root_row) == File.binread(ARGV.fetch(2))
        raise 'row list changed' unless root_row.fetch('oracleIds') == []
        raise 'row platform map changed' unless root_row.fetch('platform').fetch('supported') == true
        raise 'successor predecessor changed' unless successor_set.fetch('members').fetch(1).fetch('predecessorRelease') == '6.12.113.1'
        raise 'successor set did not round-trip' unless JSON.generate(successor_set) == File.binread(ARGV.fetch(3))
        raise 'fix row did not round-trip' unless JSON.generate(fix_row) == File.binread(ARGV.fetch(4))
        raise 'oracle map did not round-trip' unless JSON.generate(oracle_scripts) == File.binread(ARGV.fetch(5))

        oracle_script = oracle_scripts.fetch(fix_row.fetch('id'))
        expected_oracle = File.binread(ARGV.fetch(0))
        raise 'oracle bytes changed' unless oracle_script.b == expected_oracle.b
        raise 'oracle SHA changed' unless Digest::SHA256.hexdigest(oracle_script.b) == Digest::SHA256.file(ARGV.fetch(0)).hexdigest
        raise 'producer interpolation changed' unless oracle_script.include?('#{producer}')
        raise 'identity interpolation changed' unless oracle_script.include?(%q(#{identity.fetch('moduleSha256')}))
        raise 'module path interpolation changed' unless oracle_script.include?('#{module_path}')
        raise 'decoded delimiter line changed' unless oracle_script.lines.map(&:chomp).include?('VPSADMINOS_LIVEPATCH_JSON_END')
      '';
      qualificationUnsupportedOracleRows = builtins.filter (
        row: row.scope == "fix"
      ) qualificationUnsupportedIntel.rows;
      qualificationAgedRows = builtins.filter (
        row: row.role == "aged-transition"
      ) qualificationPlanOne.rows;
      qualificationReleaseAgedRows = builtins.filter (
        row: row.role == "aged-transition"
      ) qualificationReleaseSelection.rows;
      compactQualificationRows =
        rows:
        map (row: {
          inherit (row)
            expectedOutcome
            profileId
            rowId
            runnerClass
            setId
            timeoutClass
            ;
        }) rows;
      qualificationPlanOneFile = pkgs.writeText "livepatch-plan-one.json" (
        builtins.toJSON qualificationPlanOne
      );
      qualificationPlanTwoFile = pkgs.writeText "livepatch-plan-two.json" (
        builtins.toJSON qualificationPlanTwo
      );
      qualificationProfileConfigFile = pkgs.writeText "livepatch-profile-config.json" (
        builtins.toJSON {
          name = "kernel-livepatch-set-generic-lifecycle-amd";
          labels = {
            livepatch-profile = "set/vendor-lifecycle";
            livepatch-set = "6.12.113.1";
          };
          tags = [ "amd-livepatch" ];
        }
      );
      qualificationGenericValidator = pkgs.writeShellScript "validate-generic-livepatch-result" ''
        exec ${pkgs.bash}/bin/bash ${(root + "/tools/livepatch/validate-generic-result.sh")} "$@"
      '';
      qualificationResultVerifier = pkgs.writeShellScript "verify-livepatch-result" ''
        exec ${pkgs.bash}/bin/bash ${(root + "/tools/livepatch/verify.sh")} "$@"
      '';
      ownedChecks = pkgs.lib.foldl' mergeChecks ((mkLivepatchContext system).batchChecks pkgs) (
        pkgs.lib.concatMap (owner: pkgs.lib.optional (owner ? checks) (owner.checks { inherit pkgs; })) (
          builtins.attrValues (import (root + "/tests/kernel-specific") { inherit (pkgs) lib; })
        )
      );
    in
    mergeChecks ownedChecks {
      livepatch-qualification =
        assert qualificationPlanOne.counts.plannedMembers == 1;
        assert qualificationPlanOne.counts.matrixRows == 10;
        assert qualificationPlanOne.counts.coverageTuples == 2;
        assert qualificationPlanTwo.counts.plannedMembers == 2;
        assert qualificationPlanTwo.counts.matrixRows == 12;
        assert qualificationPlanTwo.counts.coverageTuples == 4;
        assert qualificationEvaluationFails qualificationMissingProfile;
        assert qualificationEvaluationFails qualificationMissingAgedSettings;
        assert qualificationEvaluationFails qualificationPartialAgedSettings;
        assert qualificationEvaluationFails qualificationExtraAgedSettings;
        assert qualificationEvaluationFails qualificationUnknownAgedClass;
        assert qualificationEvaluationFails qualificationNonIntegerAgedSettings;
        assert qualificationEvaluationFails qualificationNonPositiveAgedSettings;
        assert qualificationEvaluationFails qualificationNonIncreasingAgedSettings;
        assert qualificationEvaluationFails qualificationMissingOracle;
        assert qualificationEvaluationFails qualificationDuplicateOracle;
        assert qualificationEvaluationFails qualificationAuthoredRunnerClass;
        assert qualificationEvaluationFails qualificationFlatOraclePath;
        assert qualificationEvaluationFails qualificationLeadingZeroOraclePath;
        assert qualificationEvaluationFails qualificationMissingPlatformRunner;
        assert qualificationEvaluationFails qualificationEmptyPlatformRunner;
        assert qualificationEvaluationFails qualificationWrongPlatformRunner;
        assert qualificationEvaluationFails qualificationUnknownApplicablePlatform;
        assert qualificationEvaluationFails qualificationAbsentApplicablePlatform;
        assert qualificationEvaluationFails qualificationDuplicateApplicablePlatform;
        assert builtins.length qualificationAgedRows == 2;
        assert builtins.all (
          row:
          row.aging == {
            checkpointSeconds = 60;
            developmentDwellSeconds = 300;
            dwellSeconds = 300;
            evidenceClass = "development-short";
            releaseDwellSeconds = 1800;
          }
        ) qualificationAgedRows;
        assert builtins.length qualificationReleaseAgedRows == 2;
        assert builtins.all (
          row:
          row.aging == {
            checkpointSeconds = 60;
            developmentDwellSeconds = 300;
            dwellSeconds = 1800;
            evidenceClass = "release";
            releaseDwellSeconds = 1800;
          }
        ) qualificationReleaseAgedRows;
        assert
          map (row: builtins.removeAttrs row [ "aging" ]) qualificationPlanOne.rows
          == map (row: builtins.removeAttrs row [ "aging" ]) qualificationReleaseSelection.rows;
        assert
          qualificationOracleRows == [
            {
              expectedOutcome = "success";
              fixId = "fix-a";
              id = "oracle-a";
              oracleIds = [ "oracle-a" ];
              oracleShard = "oracle-a";
              platform = {
                id = "amd";
                runnerClass = "amd-livepatch";
                supported = true;
              };
              platformId = "amd";
              platforms = [
                "amd"
                "intel"
              ];
              profileId = "fix/fix-a/oracle-a";
              role = "fixed-path";
              rowId = "6.12.113.1--fix-fix-a-oracle-a--amd";
              runnerClass = "amd-livepatch";
              scope = "fix";
              setId = "6.12.113.1";
              supported = true;
              template = "kernel/livepatch-fix";
              testAdapter = "os/livepatches/batches/6.12.113/1/qualification/helpers/fix-a.nix";
              timeoutClass = "oracle";
              validator = "os/livepatches/batches/6.12.113/1/qualification/validators/fix-a.sh";
            }
            {
              expectedOutcome = "success";
              fixId = "fix-a";
              id = "oracle-a";
              oracleIds = [ "oracle-a" ];
              oracleShard = "oracle-a";
              platform = {
                id = "intel";
                runnerClass = "intel-kvm";
                supported = true;
              };
              platformId = "intel";
              platforms = [
                "amd"
                "intel"
              ];
              profileId = "fix/fix-a/oracle-a";
              role = "fixed-path";
              rowId = "6.12.113.1--fix-fix-a-oracle-a--intel";
              runnerClass = "intel-kvm";
              scope = "fix";
              setId = "6.12.113.1";
              supported = true;
              template = "kernel/livepatch-fix";
              testAdapter = "os/livepatches/batches/6.12.113/1/qualification/helpers/fix-a.nix";
              timeoutClass = "oracle";
              validator = "os/livepatches/batches/6.12.113/1/qualification/validators/fix-a.sh";
            }
          ];
        assert
          builtins.elemAt qualificationUnsupportedOracleRows 0 == builtins.elemAt qualificationOracleRows 0;
        assert
          (builtins.elemAt qualificationUnsupportedOracleRows 1).platform == {
            id = "intel";
            runnerClass = "intel-kvm";
            supported = false;
            unsupportedReason = "Intel qualification runner unavailable";
          };
        assert (builtins.elemAt qualificationUnsupportedOracleRows 1).runnerClass == "intel-kvm";
        assert (builtins.elemAt qualificationUnsupportedOracleRows 1).supported == false;
        assert (builtins.elemAt qualificationUnsupportedOracleRows 1).expectedOutcome == "blocked";
        assert
          (builtins.elemAt qualificationUnsupportedOracleRows 1).unsupportedReason
          == "Intel qualification runner unavailable";
        assert qualificationPlanOne.matrix.include == compactQualificationRows qualificationPlanOne.rows;
        assert
          qualificationUnsupportedIntel.matrix.include
          == compactQualificationRows qualificationUnsupportedIntel.rows;
        pkgs.runCommand "livepatch-qualification-check"
          {
            livepatchCiTools = livepatchCiTools.${system};
            inherit stackManagerReceipt stackManagerUnit;
            nativeBuildInputs = [
              pkgs.bash
              pkgs.coreutils
              pkgs.diffutils
              pkgs.findutils
              pkgs.gawk
              pkgs.gnugrep
              pkgs.jq
            ];
          }
          ''
            set -euo pipefail
            one=${qualificationPlanOneFile}
            two=${qualificationPlanTwoFile}

            test -e "$stackManagerUnit"
            jq -e '
              .instance == "production-manager-private-stack"
              and .name == "kernel-livepatch-production-manager-stack"
              and .machines == ["boot_on", "machine", "switch_off", "switch_on"]
              and .tags == ["ci"]
            ' "$stackManagerReceipt" > livepatch-stack-manager-render.log
            grep -F 'live-patches load 1' ${(root + "/tests/suite/kernel/livepatch-set/manager.nix")}
            grep -F 'live-patches unload 3' ${(root + "/tests/suite/kernel/livepatch-set/manager.nix")}
            grep -F 'module_param_cb(stack_value' ${(root + "/tests/suite/kernel/livepatch-set/manager.nix")}
            grep -F 'loadOnSwitch = false;' ${(root + "/tests/suite/kernel/livepatch-set/manager.nix")}
            grep -F 'kernelImage = switchKernelImage;' ${
              (root + "/tests/suite/kernel/livepatch-set/manager.nix")
            }
            grep -F 'configured_modules = lambda do |guest|' ${
              (root + "/tests/suite/kernel/livepatch-set/manager.nix")
            }
            grep -F '/run/booted-system/kernel-modules' ${
              (root + "/tests/suite/kernel/livepatch-set/manager.nix")
            }
            grep -F "switch_off.succeeds('live-patches load'" ${
              (root + "/tests/suite/kernel/livepatch-set/manager.nix")
            }
            grep -F "switch_off.succeeds('live-patches unload'" ${
              (root + "/tests/suite/kernel/livepatch-set/manager.nix")
            }
            grep -F 'managerFixture = true;' ${(root + "/tests/all-tests.nix")}
            if grep -E 'compatibility|nfs-livepatch|nfs-sysfs|batches/6[.]12[.]113' \
              ${(root + "/tests/suite/kernel/livepatch-set.nix")}; then
              echo 'generic livepatch-set template contains release-specific fixture logic' >&2
              exit 1
            fi

            ${pkgs.ruby}/bin/ruby ${qualificationSerializationCheck} \
              ${qualificationOracleScriptFile} \
              ${qualificationRootSetJsonFile} \
              ${qualificationRootRowJsonFile} \
              ${qualificationSuccessorSetJsonFile} \
              ${qualificationFixRowJsonFile} \
              ${qualificationOracleScriptMapJsonFile} \
              > qualification-serialization.log
            grep -F 'rubyJson = import (root + "/livepatch-ruby-json.nix")' ${
              (root + "/tests/suite/kernel/livepatch-set.nix")
            }
            grep -F 'rubyJson = import (root + "/livepatch-ruby-json.nix")' ${
              (root + "/tests/suite/kernel/livepatch-fix.nix")
            }
            grep -F 'VPSADMINOS_LIVEPATCH_JSON_END' ${(root + "/tests/suite/kernel/livepatch-ruby-json.nix")}
            grep -F 'assert !lib.hasInfix' ${(root + "/tests/suite/kernel/livepatch-ruby-json.nix")}
            grep -F "JSON.parse(<<~'" ${(root + "/tests/suite/kernel/livepatch-ruby-json.nix")}
            if grep -F 'builtins.toJSON' \
              ${(root + "/tests/suite/kernel/livepatch-set.nix")} \
              ${(root + "/tests/suite/kernel/livepatch-fix.nix")}; then
              echo 'production template bypasses the shared Ruby JSON carrier' >&2
              exit 1
            fi

            jq -e '
              .selectedSets == 1
              and (.sets[0].members | length) == 1
              and ([.matrix.include[].runnerClass] | unique | sort) == ["amd-livepatch", "intel-kvm"]
              and ([.rows[] | select(.scope == "set") | .role] | unique | sort) == ["aged-transition", "busy-transition", "failure-recovery", "lifecycle"]
              and ([.rows[] | select(.role == "aged-transition")] | length) == 2
              and ([.rows[] | select(.role == "aged-transition") | .aging.evidenceClass] | unique) == ["development-short"]
              and ([.rows[] | select(.role == "aged-transition") | .aging.dwellSeconds] | unique) == [300]
              and ([.rows[] | select(.scope == "set") | .oracleIds] | all(. == []))
              and ([.rows[] | select(.scope == "set") | .oracleShard] | all(. == "none"))
              and ([.rows[] | select(.scope == "set") | .validator] | all(. == "builtin/generic-livepatch-safety-v1"))
              and (.coverage | length) == 2
            ' "$one" >/dev/null

            jq -e '
              .selectedSets == 1
              and (.sets[0].members | map(.release)) == ["6.12.113.1", "6.12.113.2"]
              and .sets[0].members[1].predecessorRelease == "6.12.113.1"
              and .counts.plannedMembers == 2
              and .counts.matrixRows == 12
              and .counts.coverageTuples == 4
              and ([.rows[] | select(.scope == "set") | .oracleIds] | all(. == []))
              and ([.coverage[] | .oracleId] | sort) == ["oracle-a", "oracle-a", "oracle-b", "oracle-b"]
            ' "$two" >/dev/null

            grep -F 'rawBuildLogIdentity: "per-realization-only"' ${(root + "/tools/livepatch/capture.sh")}
            grep -F 'def canonical_callbacks: sort_by([.kind, .object, .symbol]);' ${
              (root + "/tools/livepatch/capture.sh")
            }
            grep -F '.audit.buildLogSha256' ${(root + "/tools/livepatch/verify.sh")}

            jq -n '{
              callbacks: [
                {kind: "pre_patch", object: "vmlinux", symbol: "level_pre"},
                {kind: "post_patch", object: "vmlinux", symbol: "level_post"},
                {kind: "post_unpatch", object: "vmlinux", symbol: "level_unpost"}
              ]
            }' > callbacks-expected.json
            jq '.callbacks |= reverse' callbacks-expected.json > callbacks-reordered.json
            jq '.callbacks |= .[1:]' callbacks-expected.json > callbacks-missing.json
            jq '.callbacks += [{kind: "pre_unpatch", object: "vmlinux", symbol: "level_unpre"}]' \
              callbacks-expected.json > callbacks-extra.json
            jq '.callbacks[0].symbol = "level_changed"' \
              callbacks-expected.json > callbacks-changed.json
            jq '.callbacks += [.callbacks[0]]' callbacks-expected.json > callbacks-duplicate.json

            callbacks_match() {
              jq -e --slurpfile expected callbacks-expected.json '
                def canonical_callbacks: sort_by([.kind, .object, .symbol]);

                (.callbacks | canonical_callbacks)
                  == ($expected[0].callbacks | canonical_callbacks)
              ' "$1" >/dev/null
            }

            callbacks_match callbacks-reordered.json
            for invalid in callbacks-missing.json callbacks-extra.json \
              callbacks-changed.json callbacks-duplicate.json; do
              if callbacks_match "$invalid"; then
                echo "invalid callback inventory accepted: $invalid" >&2
                exit 1
              fi
            done

            ${pkgs.bash}/bin/bash ${(root + "/tools/livepatch/tests/generic-safety-hypervisor.sh")} \
              ${(root + "/tests/suite/kernel/livepatch-set.nix")} \
              > generic-safety-hypervisor.log

            ${pkgs.bash}/bin/bash ${(root + "/tools/livepatch/tests/generic-safety.sh")} \
              ${qualificationGenericValidator} \
              ${qualificationResultVerifier} \
              ${pkgs.ruby}/bin/ruby \
              ${(root + "/tests/suite/kernel/livepatch-set.nix")} \
              ${pkgs.python3}/bin/python3 \
              ${(root + "/tests/suite/kernel/livepatch-set/workload.nix")} \
              ${qualificationWorkloadPackage}/bin/livepatch-generic-workload \
              ${(root + "/tools/livepatch/run-profile.sh")} \
              ${qualificationProfileConfigFile} \
              ${(root + "/tools/livepatch/tests/profile-fixture.sh")} \
              ${(root + "/tools/livepatch/tests/reverse-fixture.sh")} \
              > generic-safety.log

            PYTHONPYCACHEPREFIX="$PWD/python-cache" \
              ${pkgs.python3}/bin/python3 -m py_compile \
              ${qualificationWorkloadPackage}/bin/livepatch-generic-workload
            grep -Fx 'generic workload initialization matrix passed' \
              generic-safety.log > workload-init.log
            grep -Fx 'generic workload CLI exit matrix passed' \
              generic-safety.log > workload-cli.log
            sha256sum ${qualificationWorkloadPackage}/bin/livepatch-generic-workload \
              > workload-generated.sha256

            ${pkgs.bash}/bin/bash ${(root + "/tools/livepatch/tests/verify-capture.sh")} \
              ${pkgs.bash}/bin/bash \
              ${qualificationResultVerifier} \
              ${(root + "/tools/livepatch/capture.sh")} \
              ${(root + "/tools/livepatch/run-profile.sh")} \
              ${(root + "/tools/livepatch/ci-workspace.sh")} \
              ${(root + "/.github/workflows/livepatch.yml")} \
              > verify-capture.log

            ${pkgs.bash}/bin/bash ${(root + "/tools/livepatch/tests/ci-tool-closure.sh")} \
              ${root} "$livepatchCiTools" > ci-tool-closure.log

            mkdir "$out"
            printf '%s\n' "$livepatchCiTools" > "$out/livepatch-ci-tools-path.txt"
            printf '%s\n' ${qualificationProfileConfigFile} > "$out/livepatch-profile-config-path.txt"
            cp "$one" "$out/plan-one.json"
            cp "$two" "$out/plan-two.json"
            cp qualification-serialization.log "$out/qualification-serialization.log"
            cp generic-safety-hypervisor.log "$out/generic-safety-hypervisor.log"
            cp generic-safety.log "$out/generic-safety.log"
            cp workload-init.log "$out/workload-init.log"
            cp workload-cli.log "$out/workload-cli.log"
            cp workload-generated.sha256 "$out/workload-generated.sha256"
            cp verify-capture.log "$out/verify-capture.log"
            cp ci-tool-closure.log "$out/ci-tool-closure.log"
          '';
    }
  );
}
