args@{
  pkgs ? <nixpkgs>,
  row,
  system ? builtins.currentSystem,
  ...
}:

let
  nixpkgs = import pkgs { inherit system; };
  lib = nixpkgs.lib;
  livepatchLib = import ../../../../os/livepatches/lib.nix { inherit lib; };
  kernelOwner = import ../../../../os/packages/linux/packages.nix {
    config.system.vpsadminos.enableUnstable = false;
    inherit lib;
    pkgs = nixpkgs;
  };
  kernelVersion = kernelOwner.defaultVersion;
  kernel = kernelOwner.genKernelPackage kernelVersion;
  targetModuleName = "livepatch_stack_target";
  targetFunction = "livepatch_stack_value";
  fixturePatch = ../../../../os/packages/livepatch-module/tests/fixtures/a.patch;
  builderInput = nixpkgs.writeText "livepatch-stack-private-kpatch" "fixture only\n";
  builder = {
    kpatchBuild = toString builderInput;
    kpatchRevision = "bea635fbbeb11c5f0f5c0d4ffce34c2e9d2e8a6a";
  };
  function = {
    object = targetModuleName;
    symbol = targetFunction;
    sympos = 0;
  };
  mkDescriptor =
    ordinal:
    let
      release = "${kernelVersion}.${toString ordinal}";
      predecessorOrdinal = ordinal - 1;
      predecessorRelease = "${kernelVersion}.${toString predecessorOrdinal}";
    in
    {
      inherit kernelVersion release;
      payloadRevision = ordinal;
      mode = "additive";
      build = {
        targets = [ targetModuleName ];
        expected = {
          callbacks = [ ];
          functions = [ function ];
          imports = [ ];
          relocations = [ ];
          states = [ ];
        };
      };
      fixes = [
        {
          id = "private-stack-${toString ordinal}";
          patchIds = [ "private-stack-${toString ordinal}" ];
          cves = [ ];
          functions = [ function ];
          oracleIds = [ ];
          prerequisites = [ ];
          provenance = {
            source = {
              repository = "vpsfreecz/vpsadminos-private-test";
              commit = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
            };
            status = "downstream-only";
            upstream = null;
            stable = null;
          };
        }
      ];
      patches = [
        {
          id = "private-stack-${toString ordinal}";
          path = fixturePatch;
          fixIds = [ "private-stack-${toString ordinal}" ];
        }
      ];
      lineage = {
        predecessorBatch =
          if ordinal == 1 then
            null
          else
            {
              release = predecessorRelease;
              payloadRevision = predecessorOrdinal;
            };
        functions =
          if ordinal == 1 then
            [ ]
          else
            [
              (
                function
                // {
                  predecessorOwner = {
                    release = predecessorRelease;
                    payloadRevision = predecessorOrdinal;
                  };
                }
              )
            ];
        states = [ ];
      };
      runtime = {
        prevention = "private production-manager fixture only";
        removal = "unload the private fixture stack";
        recovery = "reboot the disposable test guest";
      };
    };
  descriptors = map mkDescriptor [
    1
    2
    3
  ];
  mkCatalogUnit = batch: {
    inherit batch;
    qualification = {
      schemaVersion = 1;
      release = batch.release;
      requiredGenericProfiles = [ ];
      platforms = { };
      oracles = { };
    };
    documentation = {
      page = "private/livepatch-stack";
      anchor = "release-${lib.replaceStrings [ "." ] [ "-" ] batch.release}";
    };
  };
  catalog = map mkCatalogUnit descriptors;

  targetSource = nixpkgs.runCommand "livepatch-stack-target-source" { } ''
    mkdir -p "$out"
    cat > "$out/${targetModuleName}.c" <<'SOURCE_END'
    #include <linux/module.h>

    noinline int ${targetFunction}(void)
    {
      return 0;
    }
    EXPORT_SYMBOL_GPL(${targetFunction});

    MODULE_LICENSE("GPL");
    MODULE_DESCRIPTION("Private STACK1 livepatch target");
    SOURCE_END
    cat > "$out/Makefile" <<'MAKEFILE_END'
    obj-m += ${targetModuleName}.o
    MAKEFILE_END
  '';
  targetModule = kernel.stdenv.mkDerivation {
    pname = targetModuleName;
    version = kernel.modDirVersion;
    src = targetSource;
    nativeBuildInputs = kernel.moduleBuildDependencies ++ [ nixpkgs.gnumake ];
    hardeningDisable = [ "pic" ];
    dontStrip = true;
    buildPhase = ''
      runHook preBuild
      make -C ${kernel.dev}/lib/modules/${kernel.modDirVersion}/build M="$PWD" modules
      runHook postBuild
    '';
    installPhase = ''
      runHook preInstall
      install -Dm444 ${targetModuleName}.ko \
        "$out/lib/modules/${kernel.modDirVersion}/extra/${targetModuleName}.ko"
      runHook postInstall
    '';
  };

  mkLivepatchModule =
    batch: targetBuild:
    let
      moduleSource = nixpkgs.runCommand "${batch.moduleName}-source" { } ''
        mkdir -p "$out"
        cat > "$out/${batch.moduleName}.c" <<'SOURCE_END'
        #include <linux/compiler.h>
        #include <linux/errno.h>
        #include <linux/livepatch.h>
        #include <linux/module.h>
        #include <linux/string.h>
        #include <linux/utsname.h>

        #define STACK_STATE_ID 0x48573a1786d6fe85UL
        #define STACK_STATE_VERSION 1U
        #define STACK_ORDINAL ${toString batch.unameLevel.releaseOrdinal}UL
        #define STACK_PUBLISHED_RELEASE "${batch.unameLevel.publishedRelease}"
        #define STACK_ROLLBACK_RELEASE "${batch.unameLevel.rollbackRelease}"

        static struct klp_state stack_states[] = {
          {
            .id = STACK_STATE_ID,
            .version = STACK_STATE_VERSION,
            .data = NULL,
          },
          { }
        };

        static bool predecessor_matches(void)
        {
          struct klp_state *previous = klp_get_prev_state(STACK_STATE_ID);

        #if ${toString batch.unameLevel.releaseOrdinal} == 1
          return !previous;
        #else
          return previous && previous->version == STACK_STATE_VERSION &&
                 (unsigned long)READ_ONCE(previous->data) == STACK_ORDINAL - 1;
        #endif
        }

        static bool release_matches(const char *expected)
        {
          return !strcmp(init_uts_ns.name.release, expected);
        }

        static void publish_release(const char *release, void *state_data)
        {
          strscpy(init_uts_ns.name.release, release,
                  sizeof(init_uts_ns.name.release));
          WRITE_ONCE(stack_states[0].data, state_data);
        }

        static int stack_pre_patch(struct klp_object *object)
        {
          (void)object;
          if (READ_ONCE(stack_states[0].data) || !predecessor_matches() ||
              !release_matches(STACK_ROLLBACK_RELEASE))
            return -ESTALE;
          return 0;
        }

        static void stack_post_patch(struct klp_object *object)
        {
          (void)object;
          publish_release(STACK_PUBLISHED_RELEASE,
                          (void *)(unsigned long)STACK_ORDINAL);
        }

        static void stack_post_unpatch(struct klp_object *object)
        {
          (void)object;
          publish_release(STACK_ROLLBACK_RELEASE, NULL);
        }

        static noinline int patched_stack_value(void)
        {
          return ${toString batch.unameLevel.releaseOrdinal};
        }

        static struct klp_func callback_funcs[] = {
          { }
        };
        static struct klp_func target_funcs[] = {
          {
            .old_name = "${targetFunction}",
            .new_func = patched_stack_value,
          },
          { }
        };
        static struct klp_object objects[] = {
          {
            .funcs = callback_funcs,
            .callbacks = {
              .pre_patch = stack_pre_patch,
              .post_patch = stack_post_patch,
              .post_unpatch = stack_post_unpatch,
            },
          },
          {
            .name = "${targetModuleName}",
            .funcs = target_funcs,
          },
          { }
        };
        static struct klp_patch patch = {
          .mod = THIS_MODULE,
          .objs = objects,
          .states = stack_states,
          .replace = false,
        };

        static int __init stack_init(void)
        {
          return klp_enable_patch(&patch);
        }
        static void __exit stack_exit(void)
        {
        }

        module_init(stack_init);
        module_exit(stack_exit);
        MODULE_LICENSE("GPL");
        MODULE_INFO(livepatch, "Y");
        MODULE_DESCRIPTION("Private STACK1 additive livepatch fixture");
        SOURCE_END
        cat > "$out/Makefile" <<'MAKEFILE_END'
        obj-m += ${batch.moduleName}.o
        MAKEFILE_END
      '';
      manifestFile = nixpkgs.writeText "${batch.moduleName}-manifest.json" (
        builtins.toJSON batch.manifest
      );
    in
    (kernel.stdenv.mkDerivation {
      pname = batch.moduleName;
      version = batch.release;
      src = moduleSource;
      nativeBuildInputs = kernel.moduleBuildDependencies ++ [
        nixpkgs.gnumake
        nixpkgs.jq
      ];
      hardeningDisable = [ "pic" ];
      dontStrip = true;
      buildPhase = ''
        runHook preBuild
        make -C ${targetBuild.dev}/lib/modules/${targetBuild.modDirVersion}/build \
          M="$PWD" modules
        runHook postBuild
      '';
      installPhase = ''
        runHook preInstall
        module="$out/${batch.installPath}"
        evidence="$out/share/vpsadminos-livepatch"
        install -Dm444 ${batch.moduleName}.ko "$module"
        mkdir -p "$evidence"
        cp ${manifestFile} "$evidence/manifest.json"
        sha=$(sha256sum "$module" | cut -d ' ' -f 1)
        jq -n --arg name ${lib.escapeShellArg batch.moduleName} --arg sha "$sha" \
          '{
            buildInvocation: {
              flags: ["--non-replace"],
              nonReplaceRequested: true
            },
            module: { name: $name, sha256: $sha }
          }' > "$evidence/inspection.json"
        jq -n '{ schemaVersion: 1, matches: true, mismatches: {} }' \
          > "$evidence/closure.json"
        runHook postInstall
      '';
      passthru = {
        inherit batch;
        kernelTarget = batch.kernelTarget;
        manifest = batch.manifest;
        targetIdentity = targetBuild.identity;
      };
    });

  kernelNotes =
    nixpkgs.runCommand "livepatch-stack-kernel-notes"
      {
        nativeBuildInputs = [ nixpkgs.buildPackages.binutils ];
      }
      ''
        objcopy -O binary --only-section=.notes ${kernel.dev}/vmlinux "$out"
        test -s "$out"
      '';
  livepatchTest = {
    inherit builder catalog kernelNotes;
    kpatchBuild = builderInput;
    kernelImage = "${kernel}/bzImage";
    livepatchModule =
      {
        batch,
        kpatchBuild,
        targetBuild,
      }:
      assert toString kpatchBuild == toString builderInput;
      mkLivepatchModule batch targetBuild;
    runtime = {
      appliedDir = "/run/vpsadminos/livepatches";
      bootedKernel = "/run/booted-system/kernel";
      date = "${nixpkgs.coreutils}/bin/date";
      disable = nixpkgs.writeShellScript "livepatch-stack-disable" ''
        printf '0\n' > "$1"
      '';
      insmod = "${nixpkgs.kmod}/bin/insmod";
      livepatchRoot = "/sys/kernel/livepatch";
      lockFile = "/run/lock/vpsadminos-livepatch";
      modulesRoot = "/lib/modules";
      bootedModulesTree = "/run/booted-system/kernel-modules";
      storeRoot = "/nix/store";
      pollAttempts = 180;
      pollInterval = "1";
      rmmod = "${nixpkgs.kmod}/bin/rmmod";
      runningNotes = "/sys/kernel/notes";
      sysModuleRoot = "/sys/module";
      uname = "${nixpkgs.coreutils}/bin/uname";
    };
  };
  rootOnlyLivepatchTest = livepatchTest // {
    catalog = [ (builtins.head catalog) ];
  };

  makeTest = import ../../../make-test.nix (
    { pkgs }:
    let
      fixtureInputs = pkgs.vpsadminosTestFrameworkInputs or { };
      switchedSystem =
        selectedLivepatchTest: module:
        (import ../../../../os {
          importedPkgs = pkgs;
          system = pkgs.system;
          extraArgs = fixtureInputs // {
            livepatchTest = selectedLivepatchTest;
          };
          modules = [
            ../../../configs/vpsadminos/base.nix
            ../../../configs/vpsadminos/pool-tank.nix
            { boot.zfsBuiltin = pkgs.lib.mkForce false; }
            module
          ];
        }).config.system.build.toplevel;
      fullSystem = switchedSystem livepatchTest {
        services.live-patches = {
          enable = true;
          loadOnBoot = false;
          loadOnSwitch = false;
        };
      };
      rootOnlySystem = switchedSystem rootOnlyLivepatchTest {
        services.live-patches = {
          enable = true;
          loadOnBoot = false;
          loadOnSwitch = false;
        };
      };
      switchSystem = switchedSystem livepatchTest {
        services.live-patches = {
          enable = true;
          loadOnBoot = false;
          loadOnSwitch = true;
        };
      };
      machineConfig =
        policy:
        {
          config,
          lib,
          ...
        }:
        {
          boot.extraModulePackages = [ targetModule ];
          boot.initrd.kernelModules = [ targetModuleName ];
          boot.zfsBuiltin = lib.mkForce false;
          services.live-patches = {
            enable = true;
            inherit (policy) loadOnBoot loadOnSwitch;
          };
          environment.systemPackages = [
            config.system.build.livePatchManager
            nixpkgs.coreutils
            nixpkgs.kmod
          ];
          system.extraDependencies = [
            fullSystem
            rootOnlySystem
            switchSystem
          ];
          system.vpsadminos.enableUnstable = lib.mkForce false;
        };
    in
    {
      name = "kernel-livepatch-production-manager-stack";
      description = "Production livepatch manager with a private three-batch stack";
      tags = [ "ci" ];

      machines = {
        machine = import ../../../machines/vpsadminos/with-empty.nix {
          inherit pkgs;
          config = machineConfig {
            loadOnBoot = false;
            loadOnSwitch = false;
          };
        };
        boot_on = import ../../../machines/vpsadminos/with-empty.nix {
          inherit pkgs;
          config = machineConfig {
            loadOnBoot = true;
            loadOnSwitch = false;
          };
        };
        switch_on = import ../../../machines/vpsadminos/with-empty.nix {
          inherit pkgs;
          config = machineConfig {
            loadOnBoot = false;
            loadOnSwitch = false;
          };
        };
      };

      testScript = ''
        status_state = lambda do |guest, ordinal, state|
          output = guest.succeeds('live-patches status')[1]
          row = output.lines.find { |line| line.start_with?("ordinal=#{ordinal} ") }
          expect(row).not_to be_nil
          expect(row).to include("ordinal=#{ordinal}")
          expect(row).to include("state=#{state}")
          output
        end

        describe 'production livepatch manager private stack', order: :defined do
          before(:context) do
            machine.start
          end

          it 'loads selected and aggregate batches in strict order' do
            expect(machine.succeeds('uname -r')[1].strip).to eq('${kernelVersion}')
            status_state.call(machine, 1, 'configured-not-loaded')
            status_state.call(machine, 2, 'configured-not-loaded')
            status_state.call(machine, 3, 'configured-not-loaded')
            machine.succeeds('live-patches load 1', timeout: 240)
            expect(machine.succeeds('uname -r')[1].strip).to eq('${kernelVersion}.1')
            status_state.call(machine, 1, 'active')
            status_state.call(machine, 2, 'configured-not-loaded')
            status_state.call(machine, 3, 'configured-not-loaded')
            machine.fails('live-patches load 3', timeout: 60)
            expect(machine.succeeds('uname -r')[1].strip).to eq('${kernelVersion}.1')
            machine.succeeds('live-patches load 2', timeout: 240)
            expect(machine.succeeds('uname -r')[1].strip).to eq('${kernelVersion}.2')
            status_state.call(machine, 1, 'active')
            status_state.call(machine, 2, 'active')
            status_state.call(machine, 3, 'configured-not-loaded')
            machine.succeeds('live-patches load', timeout: 480)
            expect(machine.succeeds('uname -r')[1].strip).to eq('${kernelVersion}.3')
            status_state.call(machine, 1, 'active')
            status_state.call(machine, 2, 'active')
            status_state.call(machine, 3, 'active')
          end

          it 'refuses a non-tip removal without changing the stack' do
            machine.fails('live-patches unload 1', timeout: 60)
            expect(machine.succeeds('uname -r')[1].strip).to eq('${kernelVersion}.3')
          end

          it 'reports loaded modules after a generation rollback without adopting them' do
            machine.succeeds('${rootOnlySystem}/bin/switch-to-configuration test', timeout: 180)
            status = machine.succeeds('live-patches status')[1]
            expect(status).to include('configured=yes present=yes')
            expect(status.scan('configured=no present=yes').length).to eq(2)
            machine.fails('live-patches unload', timeout: 60)
            expect(machine.succeeds('uname -r')[1].strip).to eq('${kernelVersion}.3')
            machine.succeeds('${fullSystem}/bin/switch-to-configuration test', timeout: 180)
          end

          it 'rolls back and reloads the tip, then returns to native' do
            machine.succeeds('live-patches unload 3', timeout: 240)
            expect(machine.succeeds('uname -r')[1].strip).to eq('${kernelVersion}.2')
            status_state.call(machine, 1, 'active')
            status_state.call(machine, 2, 'active')
            status_state.call(machine, 3, 'configured-not-loaded')
            machine.succeeds('live-patches load 3', timeout: 240)
            expect(machine.succeeds('uname -r')[1].strip).to eq('${kernelVersion}.3')
            machine.succeeds('live-patches unload', timeout: 480)
            expect(machine.succeeds('uname -r')[1].strip).to eq('${kernelVersion}')
            status_state.call(machine, 1, 'configured-not-loaded')
            status_state.call(machine, 2, 'configured-not-loaded')
            status_state.call(machine, 3, 'configured-not-loaded')
          end

          it 'keeps a verified prefix when the next admitted module cannot load' do
            machine.succeeds('live-patches load 1', timeout: 240)
            status_state.call(machine, 1, 'active')
            machine.succeeds("sh -c 'printf 1 > /proc/sys/kernel/modules_disabled'")
            machine.fails('live-patches load 2', timeout: 60)
            expect(machine.succeeds('uname -r')[1].strip).to eq('${kernelVersion}.1')
            status_state.call(machine, 1, 'active')
            status_state.call(machine, 2, 'partial/inconsistent')
            status_state.call(machine, 3, 'configured-not-loaded')
            machine.succeeds("test \"$(ls -A /sys/kernel/livepatch | wc -l)\" -eq 1")
          end

          it 'loads the aggregate once at boot and never on service restart' do
            boot_on.start
            boot_on.succeeds('test -d /sys/module/${targetModuleName}')
            expect(boot_on.succeeds('uname -r')[1].strip).to eq('${kernelVersion}.3')
            status_state.call(boot_on, 1, 'active')
            status_state.call(boot_on, 2, 'active')
            status_state.call(boot_on, 3, 'active')
            boot_on.succeeds('sv restart live-patches')
            expect(boot_on.succeeds('uname -r')[1].strip).to eq('${kernelVersion}.3')
            boot_on.succeeds('live-patches unload', timeout: 480)
            expect(boot_on.succeeds('uname -r')[1].strip).to eq('${kernelVersion}')
          end

          it 'loads the aggregate on an opted-in live switch and stays idempotent' do
            switch_on.start
            expect(switch_on.succeeds('uname -r')[1].strip).to eq('${kernelVersion}')
            switch_on.succeeds('${switchSystem}/bin/switch-to-configuration test', timeout: 480)
            expect(switch_on.succeeds('uname -r')[1].strip).to eq('${kernelVersion}.3')
            switch_on.succeeds('/run/current-system/bin/switch-to-configuration test', timeout: 180)
            expect(switch_on.succeeds('uname -r')[1].strip).to eq('${kernelVersion}.3')
            switch_on.succeeds('live-patches unload', timeout: 480)
            expect(switch_on.succeeds('uname -r')[1].strip).to eq('${kernelVersion}')
          end
        end
      '';
    }
  );
  rendered = makeTest (
    (builtins.removeAttrs args [
      "row"
      "templateArgs"
      "templateArgsInJson"
    ])
    // {
      extraArgs = (args.extraArgs or { }) // {
        inherit livepatchTest;
      };
    }
  );
in
{
  instance = row.rowId;
  inherit (rendered) config json;
}
