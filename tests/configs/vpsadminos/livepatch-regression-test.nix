{
  pkgs,
  root,
  system,
}:

let
  lib = pkgs.lib;
  runtimeRoot = "/tmp/vpsadminos-livepatch-regression-check";
  kernelVersion = "6.12.113";
  setId = "6.12.113.2";
  sourceRevision = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
  payloadSha256 = "e80b71cd14d3cbd65f4173abcbfcf01a545dbca32a72d575108b553a648cc96f";
  targetObjects = {
    "1" = [
      "vmlinux"
      "nf_conntrack"
      "bridge"
      "nf_conntrack"
    ];
    "2" = [
      "vmlinux"
      "bridge"
      "sctp"
    ];
    "3" = [ "unselected_object" ];
  };
  mkModule =
    ordinal:
    let
      release = "${kernelVersion}.${toString ordinal}";
      moduleName = "livepatch_regression_${toString ordinal}";
      installPath = "lib/modules/${kernelVersion}/extra/${moduleName}.ko";
    in
    pkgs.runCommand "livepatch-regression-module-${toString ordinal}"
      {
        passthru = {
          batch = {
            inherit installPath moduleName release;
            releaseOrdinal = ordinal;
            build = {
              targets = [ "build-only-dependency.ko" ];
              expected.functions = map (object: { inherit object; }) targetObjects.${toString ordinal};
            };
          };
          kernelTarget.id = "target-${kernelVersion}";
        };
      }
      ''
        mkdir -p "$out/${builtins.dirOf installPath}"
        printf 'fixture\n' > "$out/${installPath}"
      '';
  modules = map mkModule [
    1
    2
  ];
  members =
    map
      (
        ordinal:
        let
          module = builtins.elemAt modules (ordinal - 1);
          release = module.batch.release;
        in
        {
          planned = {
            inherit release;
            kernelVersion = kernelVersion;
            releaseOrdinal = ordinal;
            predecessorRelease = if ordinal == 1 then null else "${kernelVersion}.${toString (ordinal - 1)}";
            producerAttr = "synthetic-${toString ordinal}";
          };
          captured = {
            inherit release;
            identity = {
              producer = toString module;
              module = "${module}/${module.batch.installPath}";
              moduleName = module.batch.moduleName;
              moduleSha256 = payloadSha256;
              targetId = module.kernelTarget.id;
              inherit sourceRevision;
            };
          };
        }
      )
      [
        1
        2
      ];
  plan = {
    schemaVersion = 1;
    inherit sourceRevision system;
    sets = [
      {
        id = setId;
        kernelVersion = kernelVersion;
        tipRelease = setId;
        members = map (member: member.planned) members;
      }
    ];
  };
  capture = {
    schemaVersion = 1;
    inherit sourceRevision;
    sets = [
      {
        id = setId;
        members = map (member: member.captured) members;
      }
    ];
  };
  manager = pkgs.writeShellScript "livepatch-regression-manager" ''
    test "$#" -eq 1
    test "$1" = status
    printf 'gate\n' >> ${runtimeRoot}/events
    printf '%s\n' \
      'ordinal=1 release=6.12.113.1 module=livepatch_regression_1 configured=yes present=yes enabled=1 transition=0 replace=0 state=active' \
      'ordinal=2 release=6.12.113.2 module=livepatch_regression_2 configured=yes present=yes enabled=1 transition=0 replace=0 state=active'
  '';
  uname = pkgs.writeShellScript "livepatch-regression-uname" ''
    test "$#" -eq 1
    test "$1" = -r
    cat ${runtimeRoot}/uname
  '';
  modprobe = pkgs.writeShellScript "livepatch-regression-modprobe" ''
    test "$#" -eq 1
    printf 'modprobe %s\n' "$1" >> ${runtimeRoot}/events
    if test "$1" = "''${LIVEPATCH_REGRESSION_FAIL_OBJECT:-}"; then
      echo "synthetic modprobe failure for $1" >&2
      exit 1
    fi
  '';
  reboot = pkgs.writeShellScript "livepatch-regression-reboot" ''
    test "$#" -eq 1
    test "$1" = -f
    printf 'reboot %s\n' "$1" >> ${runtimeRoot}/events
  '';
  config = {
    boot.kernelVersion = kernelVersion;
    system.build.livePatchModules = builtins.listToAttrs (
      map (module: {
        name = module.batch.release;
        value = module;
      }) modules
    );
  };
  evaluateWith =
    selectedConfig: candidateCapture: selectedSetId:
    import (root + "/tests/configs/vpsadminos/livepatch-regression.nix") {
      config = selectedConfig;
      inherit lib pkgs;
      livepatchRegressionTest = {
        inherit plan;
        capture = candidateCapture;
        setId = selectedSetId;
        inherit
          runtimeRoot
          manager
          uname
          modprobe
          reboot
          ;
      };
    };
  evaluate = evaluateWith config;
  evaluated = evaluate capture setId;
  matched = (builtins.elemAt evaluated.contents 1).content;
  gate = matched.environment.etc."livepatch-regression/gate".source;
  postBootDefinition = matched.boot.postBootCommands;
  preloadDefinition = builtins.elemAt postBootDefinition.contents 0;
  gateDefinition = builtins.elemAt postBootDefinition.contents 1;
  automaticLoader = ''
    printf 'automatic-loader\n' >> ${runtimeRoot}/events
  '';
  mergePostBoot =
    value:
    let
      selected = builtins.elemAt value.contents 1;
    in
    (lib.evalModules {
      modules = [
        {
          options.boot.postBootCommands = lib.mkOption {
            default = "";
            type = lib.types.lines;
          };
        }
        { config.boot.postBootCommands = automaticLoader; }
        {
          config = lib.mkIf selected.condition {
            boot.postBootCommands = selected.content.boot.postBootCommands;
          };
        }
      ];
    }).config.boot.postBootCommands;
  mergedPostBoot = mergePostBoot evaluated;
  withoutFunctionMetadata = config // {
    system.build.livePatchModules = builtins.mapAttrs (
      _: module:
      module
      // {
        batch = module.batch // {
          build = builtins.removeAttrs module.batch.build [ "expected" ];
        };
      }
    ) config.system.build.livePatchModules;
  };
  ineligible = evaluateWith (
    withoutFunctionMetadata // { boot.kernelVersion = "6.12.114"; }
  ) capture setId;
  unselectedConfigured = evaluateWith (
    config
    // {
      system.build.livePatchModules = config.system.build.livePatchModules // {
        "${kernelVersion}.3" = mkModule 3;
      };
    }
  ) capture setId;
  allVmlinuxModules = builtins.mapAttrs (
    _: module:
    module
    // {
      batch = module.batch // {
        build = module.batch.build // {
          expected.functions = [ { object = "vmlinux"; } ];
        };
      };
    }
  ) config.system.build.livePatchModules;
  allVmlinux = evaluateWith (
    config // { system.build.livePatchModules = allVmlinuxModules; }
  ) capture setId;
  missingPredecessor = capture // {
    sets = [
      {
        id = setId;
        members = [ (builtins.elemAt members 1).captured ];
      }
    ];
  };
  wrongProducer = capture // {
    sets = [
      {
        id = setId;
        members = [
          (
            (builtins.elemAt members 0).captured
            // {
              identity = (builtins.elemAt members 0).captured.identity // {
                producer = "/nix/store/00000000000000000000000000000000-wrong-producer";
              };
            }
          )
          (builtins.elemAt members 1).captured
        ];
      }
    ];
  };
  wrongHash = capture // {
    sets = [
      {
        id = setId;
        members = [
          (
            (builtins.elemAt members 0).captured
            // {
              identity = (builtins.elemAt members 0).captured.identity // {
                moduleSha256 = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
              };
            }
          )
          (builtins.elemAt members 1).captured
        ];
      }
    ];
  };
  wrongHashEvaluated = evaluate wrongHash setId;
  wrongHashGate =
    ((builtins.elemAt wrongHashEvaluated.contents 1).content)
    .environment.etc."livepatch-regression/gate".source;
  tryEvaluation = value: builtins.tryEval (builtins.length value.contents);
  postBootFile = pkgs.writeText "livepatch-regression-post-boot" ''
    ${mergedPostBoot}
    printf 'continuation\n' >> ${runtimeRoot}/events
  '';
  allVmlinuxPostBootFile = pkgs.writeText "livepatch-regression-vmlinux-post-boot" ''
    ${mergePostBoot allVmlinux}
    printf 'continuation\n' >> ${runtimeRoot}/events
  '';

  readinessManager = pkgs.writeShellScript "livepatch-autoload-readiness-manager" ''
    test "$#" -eq 1
    test "$1" = status
    cat ${runtimeRoot}/readiness-inventory
  '';
  evaluateReadiness =
    readinessConfig:
    import (root + "/tests/configs/vpsadminos/livepatch-autoload-readiness.nix") {
      config =
        config
        // {
          services.live-patches = {
            enable = true;
            loadOnBoot = true;
          };
          system.build = config.system.build // {
            livePatchManager = readinessManager;
          };
        }
        // readinessConfig;
      inherit lib pkgs;
      livepatchAutoloadReadinessTest = {
        inherit runtimeRoot uname;
        manager = readinessManager;
      };
    };
  readinessEvaluation = evaluateReadiness { };
  readinessDormant = evaluateReadiness {
    system.build.livePatchModules = { };
  };
  readinessLoadDisabled = evaluateReadiness {
    services.live-patches = {
      enable = true;
      loadOnBoot = false;
    };
  };
  readinessPostBoot = readinessEvaluation.content.boot.postBootCommands.content;
  readinessPostBootFile = pkgs.writeText "livepatch-autoload-readiness-post-boot" readinessPostBoot;
  readinessGate =
    readinessEvaluation.content.environment.etc."livepatch-autoload-readiness/gate".source;
in
assert (tryEvaluation evaluated).success;
assert postBootDefinition._type == "merge";
assert preloadDefinition._type == "order" && preloadDefinition.priority == 500;
assert gateDefinition._type == "order" && gateDefinition.priority == 1500;
assert
  mergedPostBoot == lib.concatStringsSep "\n" [
    preloadDefinition.content
    automaticLoader
    gateDefinition.content
  ];
assert mergePostBoot ineligible == automaticLoader;
assert !(tryEvaluation unselectedConfigured).success;
assert !(tryEvaluation (evaluate capture "6.12.113.9")).success;
assert !(tryEvaluation (evaluate missingPredecessor setId)).success;
assert !(tryEvaluation (evaluate wrongProducer setId)).success;
assert !readinessDormant.condition;
assert !readinessLoadDisabled.condition;
pkgs.runCommand "livepatch-regression-interface-check"
  {
    nativeBuildInputs = [
      pkgs.bash
      pkgs.coreutils
      pkgs.gnugrep
    ];
  }
  ''
    set -euo pipefail
    root=${runtimeRoot}
    mkdir "$out"

    prepare_runtime() {
      rm -rf "$root"
      mkdir -p \
        "$root/run/booted-system/kernel-modules/lib/modules/${kernelVersion}" \
        "$root/sys/module/livepatch_regression_1" \
        "$root/sys/module/livepatch_regression_2" \
        "$root/sys/kernel/livepatch/livepatch_regression_1" \
        "$root/sys/kernel/livepatch/livepatch_regression_2"
      : > "$root/events"
      printf '%s\n' ${setId} > "$root/uname"
      for ordinal in 1 2; do
        state="$root/sys/kernel/livepatch/livepatch_regression_$ordinal"
        printf '1\n' > "$state/enabled"
        printf '0\n' > "$state/transition"
        printf '0\n' > "$state/replace"
      done
    }

    expect_refusal() {
      label=$1
      candidate=$2
      if "$candidate" > "$root/$label.out" 2> "$root/$label.err"; then
        echo "regression gate unexpectedly accepted $label" >&2
        exit 1
      fi
      test ! -e "$root/run/livepatch-regression/verified"
      grep -F 'livepatch regression gate:' "$root/$label.err" >/dev/null
    }

    prepare_runtime
    bash ${postBootFile}
    printf '%s\n' \
      'modprobe nf_conntrack' \
      'modprobe bridge' \
      'modprobe sctp' \
      'automatic-loader' \
      'gate' \
      'continuation' > "$root/events.expected"
    cmp "$root/events.expected" "$root/events"
    test -f "$root/run/livepatch-regression/verified"

    prepare_runtime
    bash ${allVmlinuxPostBootFile}
    printf '%s\n' automatic-loader gate continuation > "$root/events.expected"
    cmp "$root/events.expected" "$root/events"
    test -f "$root/run/livepatch-regression/verified"

    prepare_runtime
    mkdir -p "$root/run/livepatch-regression"
    touch "$root/run/livepatch-regression/verified"
    status=0
    LIVEPATCH_REGRESSION_FAIL_OBJECT=bridge \
      timeout --kill-after=1 2 bash ${postBootFile} \
        > "$root/preload-failed.out" 2> "$root/preload-failed.err" || status=$?
    test "$status" -eq 124
    test ! -e "$root/run/livepatch-regression/verified"
    grep -F 'livepatch regression preload: target bridge failed' \
      "$root/run/livepatch-regression/refusal" >/dev/null
    grep -F 'synthetic modprobe failure for bridge' \
      "$root/run/livepatch-regression/refusal" >/dev/null
    printf '%s\n' 'modprobe nf_conntrack' 'modprobe bridge' 'reboot -f' \
      > "$root/events.expected"
    cmp "$root/events.expected" "$root/events"
    cp "$root/run/livepatch-regression/refusal" "$out/preload-refusal.log"

    prepare_runtime
    ${gate}
    test -f "$root/run/livepatch-regression/verified"
    test "$(stat -c %a "$root/run/livepatch-regression/verified")" = 400

    rm -rf "$root/run"
    mkdir -p "$root/run/booted-system/kernel-modules/lib/modules/${kernelVersion}"
    test ! -e "$root/run/livepatch-regression/verified"
    ${gate}
    test -f "$root/run/livepatch-regression/verified"

    prepare_runtime
    rm -rf "$root/sys/module/livepatch_regression_1"
    expect_refusal missing-predecessor ${gate}

    prepare_runtime
    printf '1\n' > "$root/sys/kernel/livepatch/livepatch_regression_2/transition"
    expect_refusal transition ${gate}

    prepare_runtime
    printf '%s\n' 6.12.114.1 > "$root/uname"
    expect_refusal wrong-kernel ${gate}

    prepare_runtime
    expect_refusal wrong-hash ${wrongHashGate}
    cp "$root/wrong-hash.err" "$out/wrong-hash.log"

    prepare_readiness() {
      rm -rf "$root"
      mkdir -p "$root"
      printf '%s\n' ${setId} > "$root/uname"
      printf '%s\n' \
        'ordinal=1 release=6.12.113.1 module=livepatch_regression_1 configured=yes present=yes enabled=1 transition=0 replace=0 state=active' \
        'ordinal=2 release=6.12.113.2 module=livepatch_regression_2 configured=yes present=yes enabled=1 transition=0 replace=0 state=active' \
        > "$root/readiness-inventory"
    }

    prepare_readiness
    ${readinessGate}
    test -f "$root/run/livepatch-autoload-readiness/verified"
    rm -rf "$root/run"
    ${readinessGate}
    test -f "$root/run/livepatch-autoload-readiness/verified"

    prepare_readiness
    printf '%s\n' 6.12.114.1 > "$root/uname"
    if ${readinessGate} 2> "$root/readiness-wrong-tip.err"; then
      echo 'readiness gate accepted a wrong tip' >&2
      exit 1
    fi
    test ! -e "$root/run/livepatch-autoload-readiness/verified"

    prepare_readiness
    sed -i 's/transition=0/transition=1/' "$root/readiness-inventory"
    if ${readinessGate} 2> "$root/readiness-transition.err"; then
      echo 'readiness gate accepted a transitioning member' >&2
      exit 1
    fi

    prepare_readiness
    printf '%s\n' 'ordinal=3 release=6.12.113.3 module=unexpected configured=yes present=yes enabled=1 transition=0 replace=0 state=active' \
      >> "$root/readiness-inventory"
    if ${readinessGate} 2> "$root/readiness-unexpected.err"; then
      echo 'readiness gate accepted an unexpected row' >&2
      exit 1
    fi

    grep -F 'livepatch regression gate refused the boot; forcing guest reboot' ${postBootFile} >/dev/null
    grep -F '${reboot} -f' ${postBootFile} >/dev/null
    grep -F 'while :; do' ${postBootFile} >/dev/null
    grep -F 'livepatch automatic-load readiness refused the boot; forcing guest reboot' \
      ${readinessPostBootFile} >/dev/null
    grep -F 'reboot -f' ${readinessPostBootFile} >/dev/null
    grep -F 'while :; do' ${readinessPostBootFile} >/dev/null

    cp ${postBootFile} "$out/post-boot.sh"
    printf '%s\n' 'livepatch regression interface checks passed' > "$out/result.txt"
  ''
