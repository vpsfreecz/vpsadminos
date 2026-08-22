import ../make-test.nix (
  { pkgs }:
  let
    lib = pkgs.lib;
    sourceRoot = toString ../..;
    repoRoot = builtins.path {
      path = ../..;
      name = "vpsadminos-ebpf-livepatch-test-source";
      filter =
        path: type:
        let
          pathStr = toString path;
          relPath = if pathStr == sourceRoot then "" else lib.removePrefix "${sourceRoot}/" pathStr;
          keepPaths = [
            ""
            "os"
            "os/livepatches"
            "os/livepatches/ebpf"
            "os/modules"
            "os/modules/services"
            "os/modules/services/ebpf-livepatch"
            "os/packages"
            "os/packages/ebpf-livepatch"
            "os/packages/linux"
          ];
          keepPrefixes = [
            "os/livepatches/ebpf/"
            "os/modules/services/ebpf-livepatch/"
            "os/packages/ebpf-livepatch/"
            "os/packages/linux/"
          ];
        in
        lib.elem relPath keepPaths || lib.any (prefix: lib.hasPrefix prefix relPath) keepPrefixes;
    };
    repoRootString = toString repoRoot;
    nixpkgsPath = toString pkgs.path;
  in
  {
    name = "ebpf-livepatch";

    description = ''
      Test eBPF livepatch program registry and kernel version rules
    '';

    tags = [ "ci" ];

    machines = { };

    testScript = ''
      require 'json'
      require 'open3'

      NIX = ${builtins.toJSON "${pkgs.nix}/bin/nix"}
      NIXPKGS = ${builtins.toJSON nixpkgsPath}
      REPO_ROOT = ${builtins.toJSON repoRootString}

      def nix_eval_json(expr)
        stdout, stderr, status = Open3.capture3(
          NIX,
          'eval',
          '--impure',
          '--json',
          '--expr',
          expr
        )

        unless status.success?
          raise <<~ERROR
            nix eval failed with status #{status.exitstatus}
            stderr:
            #{stderr}
            stdout:
            #{stdout}
            expression:
            #{expr}
          ERROR
        end

        JSON.parse(stdout)
      end

      before(:suite) do
        @facts = nix_eval_json(<<~NIX)
          let
            system = builtins.currentSystem;
            pkgs = import #{NIXPKGS} { inherit system; };
            lib = pkgs.lib;
            repo = #{REPO_ROOT};

            kernelInfo = import (repo + "/os/packages/linux/available-kernels.nix") {
              inherit lib;
            };
            currentKernelVersion = kernelInfo.stableKernelVersion;

            availableFor =
              kernelVersion:
              import (repo + "/os/livepatches/ebpf/available.nix") {
                inherit lib kernelVersion;
              };

            currentAvailable = availableFor currentKernelVersion;

            summarizeProgram =
              program:
              {
                name = program.name or null;
                description = program.description or null;
                kernelRanges = program.kernelRanges or [ ];
                enable = program.enable or null;
                hasName = program ? name;
                hasDescription = program ? description;
                hasKernelRanges = program ? kernelRanges;
                hasEnable = program ? enable;
                hasBpfPrograms = program ? bpfPrograms;
                hasLinkFields = program ? linkFields;
                bpfPrograms = program.bpfPrograms or [ ];
                linkFields = currentAvailable.programLinkFields program;
                bpfProgramNamesValid =
                  (program ? bpfPrograms)
                  && program.bpfPrograms != [ ]
                  && lib.all currentAvailable.validBpfName program.bpfPrograms;
                bpfProgramNamesUnique =
                  (program ? bpfPrograms)
                  && lib.unique program.bpfPrograms == program.bpfPrograms;
                linkFieldsValid = currentAvailable.programHasValidLinkFields program;
                linkFieldsUnique =
                  lib.unique (currentAvailable.programLinkFields program)
                  == currentAvailable.programLinkFields program;
                sourceExists =
                  (program ? name)
                  && builtins.pathExists (
                    repo + ("/os/livepatches/ebpf/programs/" + program.name + ".bpf.c")
                  );
                kernelRangesValid = currentAvailable.programHasValidKernelRanges program;
              };

            evalModule =
              {
                kernelVersion,
                programs ? null,
                registryPrograms ? null,
                enable ? true,
                autoLoad ? false,
              }:
              lib.evalModules {
                specialArgs = { inherit pkgs; };
                modules = [
                  (
                    moduleArgs:
                    import (repo + "/os/modules/services/ebpf-livepatch/default.nix") (
                      moduleArgs
                      // lib.optionalAttrs (registryPrograms != null) {
                        ebpfLivepatchPrograms = registryPrograms;
                      }
                    )
                  )
                  (
                    { lib, ... }:
                    {
                      options = {
                        boot.kernelVersion = lib.mkOption {
                          type = lib.types.str;
                        };
                        boot.kernelPackage = lib.mkOption {
                          type = lib.types.attrs;
                        };
                        system.vpsadminos.revision = lib.mkOption {
                          type = lib.types.str;
                        };
                        environment.systemPackages = lib.mkOption {
                          type = lib.types.listOf lib.types.anything;
                          default = [ ];
                        };
                        environment.etc = lib.mkOption {
                          type = lib.types.attrsOf lib.types.anything;
                          default = { };
                        };
                        runit.services = lib.mkOption {
                          type = lib.types.attrsOf lib.types.anything;
                          default = { };
                        };
                        assertions = lib.mkOption {
                          type = lib.types.listOf lib.types.attrs;
                          default = [ ];
                        };
                      };

                      config =
                        let
                          programConfig = lib.optionalAttrs (programs != null) {
                            inherit programs;
                          };
                        in
                        {
                          boot.kernelVersion = kernelVersion;
                          boot.kernelPackage = {
                            modDirVersion = kernelVersion;
                            dev = repo;
                          };
                          system.vpsadminos.revision = "test-vpsadminos-revision";
                          services.ebpf-livepatch = {
                            inherit enable;
                            inherit autoLoad;
                          } // programConfig;
                        };
                    }
                  )
                ];
              };

            failedMessages =
              eval:
              map (assertion: assertion.message) (
                builtins.filter (assertion: !assertion.assertion) eval.config.assertions
              );

            baseEval = evalModule {
              kernelVersion = currentKernelVersion;
              enable = false;
            };
            manualDisabledEval = evalModule {
              kernelVersion = currentKernelVersion;
              programs = {
                lsm_example = { };
              };
            };
            serviceEval = evalModule {
              kernelVersion = currentKernelVersion;
              autoLoad = true;
            };
            unknownEval = evalModule {
              kernelVersion = currentKernelVersion;
              programs = {
                missing_program = { };
              };
            };
            outOfRangeEval = evalModule {
              kernelVersion = "5.6";
              programs = {
                ptrace_mm_guard = { };
              };
            };
            atUpperBoundEval = evalModule {
              kernelVersion = "6.12.89";
              programs = {
                ptrace_mm_guard = { };
              };
            };
            cifsAtUpperBoundEval = evalModule {
              kernelVersion = "6.12.92";
              programs = {
                cifs_spnego_guard = { };
              };
            };
            invalidProgramOptionsEval = evalModule {
              kernelVersion = currentKernelVersion;
              programs = {
                lsm_example = {
                  unexpectedOption = true;
                };
              };
            };
            invalidProgramOptionsResult = builtins.tryEval (
              builtins.deepSeq invalidProgramOptionsEval.config.services.ebpf-livepatch.programs true
            );
            syntheticProgram = {
              name = "synthetic";
              description = "Synthetic test program";
              kernelRanges = [
                {
                  sinceKernel = "5.7";
                  untilKernel = "6.0";
                }
                {
                  sinceKernel = "6.18.3";
                  untilKernel = "6.18.7";
                }
              ];
              enable = true;
            };
            syntheticRegistryProgram = syntheticProgram // {
              name = "lsm_example";
              description = "Synthetic multi-range registry program";
              bpfPrograms = [
                "lsm_cred_prep"
                "lsm_task_prctl"
                "lsm_sysctl"
              ];
              linkFields = [
                "lsm_cred_prep"
                "lsm_task_prctl"
                "lsm_sysctl"
              ];
            };
            invalidRegistryEval = evalModule {
              kernelVersion = currentKernelVersion;
              registryPrograms = [
                (
                  syntheticRegistryProgram
                  // {
                    kernelRanges = [
                      {
                        sinceKernel = "5.7";
                        untillKernel = "6.0";
                      }
                    ];
                  }
                )
              ];
            };
            secondRangeEval = evalModule {
              kernelVersion = "6.18.6";
              registryPrograms = [ syntheticRegistryProgram ];
            };
          in
          {
            inherit currentKernelVersion;

            registry = {
              programs = map summarizeProgram currentAvailable.allPrograms;
              allProgramNames = currentAvailable.allProgramNames;
              bpfNameValidation = {
                valid = currentAvailable.validBpfName "abc_123.foo";
                empty = currentAvailable.validBpfName "";
                tooLong = currentAvailable.validBpfName "1234567890123456";
                invalidCharacter = currentAvailable.validBpfName "bad-name";
              };
              linkFieldValidation = {
                valid = currentAvailable.validLinkField "abc_123";
                empty = currentAvailable.validLinkField "";
                startsWithDigit = currentAvailable.validLinkField "1abc";
                dotted = currentAvailable.validLinkField "abc.def";
              };
              kernelRangeValidation = {
                valid = currentAvailable.programHasValidKernelRanges syntheticProgram;
                empty = currentAvailable.programHasValidKernelRanges {
                  kernelRanges = [ ];
                };
                missingSince = currentAvailable.programHasValidKernelRanges {
                  kernelRanges = [
                    { untilKernel = "6.12.10"; }
                  ];
                };
                unknownAttribute = currentAvailable.programHasValidKernelRanges {
                  kernelRanges = [
                    {
                      sinceKernel = "5.7";
                      untillKernel = "6.12.10";
                    }
                  ];
                };
                nonNumeric = currentAvailable.programHasValidKernelRanges {
                  kernelRanges = [
                    { sinceKernel = "six.eighteen"; }
                  ];
                };
                whitespace = currentAvailable.programHasValidKernelRanges {
                  kernelRanges = [
                    { sinceKernel = " 6.18"; }
                  ];
                };
                reversed = currentAvailable.programHasValidKernelRanges {
                  kernelRanges = [
                    {
                      sinceKernel = "6.12.10";
                      untilKernel = "6.12.10";
                    }
                  ];
                };
                unsorted = currentAvailable.programHasValidKernelRanges {
                  kernelRanges = [
                    {
                      sinceKernel = "6.18";
                      untilKernel = "6.18.10";
                    }
                    {
                      sinceKernel = "6.12";
                      untilKernel = "6.12.10";
                    }
                  ];
                };
                overlapping = currentAvailable.programHasValidKernelRanges {
                  kernelRanges = [
                    {
                      sinceKernel = "6.12";
                      untilKernel = "6.12.10";
                    }
                    {
                      sinceKernel = "6.12.9";
                      untilKernel = "6.12.20";
                    }
                  ];
                };
                adjacent = currentAvailable.programHasValidKernelRanges {
                  kernelRanges = [
                    {
                      sinceKernel = "6.12";
                      untilKernel = "6.12.10";
                    }
                    {
                      sinceKernel = "6.12.10";
                      untilKernel = "6.12.20";
                    }
                  ];
                };
                unboundedBeforeLast = currentAvailable.programHasValidKernelRanges {
                  kernelRanges = [
                    { sinceKernel = "6.12"; }
                    { sinceKernel = "6.18"; }
                  ];
                };
              };
            };

            synthetic = {
              belowSince = currentAvailable.programMatchesKernel "5.6" syntheticProgram;
              atSince = currentAvailable.programMatchesKernel "5.7" syntheticProgram;
              atUntil = currentAvailable.programMatchesKernel "6.0" syntheticProgram;
              inGap = currentAvailable.programMatchesKernel "6.12.95" syntheticProgram;
              belowSecondSince = currentAvailable.programMatchesKernel "6.18.2" syntheticProgram;
              atSecondSince = currentAvailable.programMatchesKernel "6.18.3" syntheticProgram;
              beforeSecondUntil = currentAvailable.programMatchesKernel "6.18.6" syntheticProgram;
              atSecondUntil = currentAvailable.programMatchesKernel "6.18.7" syntheticProgram;
              secondRange = currentAvailable.programKernelRangeForVersion "6.18.6" syntheticProgram;
              patchBeforeUntil = currentAvailable.kernelRangeMatches "6.12.87" {
                sinceKernel = "6.12.0";
                untilKernel = "6.12.88";
              };
              patchAtUntil = currentAvailable.kernelRangeMatches "6.12.88" {
                sinceKernel = "6.12.0";
                untilKernel = "6.12.88";
              };
            };

            defaults = {
              beforeSince = (availableFor "5.6").programNames "5.6";
              atSince = (availableFor "5.7").programNames "5.7";
              current = currentAvailable.programNames currentKernelVersion;
              currentHasPtrace =
                currentAvailable.programAvailableForKernel currentKernelVersion "ptrace_mm_guard";
              currentHasCifsSpnego =
                currentAvailable.programAvailableForKernel currentKernelVersion "cifs_spnego_guard";
              beforePtraceUntil = (availableFor "6.12.88").programNames "6.12.88";
              atPtraceUntil = (availableFor "6.12.89").programNames "6.12.89";
              beforeCifsUntil = (availableFor "6.12.91").programNames "6.12.91";
              atCifsUntil = (availableFor "6.12.92").programNames "6.12.92";
            };

            module = {
              optionDescription = baseEval.options.services.ebpf-livepatch.programs.description;
              defaultPrograms =
                builtins.attrNames baseEval.config.services.ebpf-livepatch.programs;
              registryDefaultPrograms = currentAvailable.programNames currentKernelVersion;
              manualDisabledPrograms =
                builtins.attrNames manualDisabledEval.config.services.ebpf-livepatch.programs;
              manualDisabledMonitorConfig = builtins.fromJSON (
                builtins.unsafeDiscardStringContext manualDisabledEval.config.environment.etc."vpsadminos/ebpf-livepatch-monitor.json".text
              );
              manualDisabledFailures = failedMessages manualDisabledEval;
              assertionMessages = map (assertion: assertion.message) manualDisabledEval.config.assertions;
              unknownFailures = failedMessages unknownEval;
              outOfRangeFailures = failedMessages outOfRangeEval;
              atUpperBoundFailures = failedMessages atUpperBoundEval;
              cifsAtUpperBoundFailures = failedMessages cifsAtUpperBoundEval;
              invalidRegistryFailures = failedMessages invalidRegistryEval;
              invalidProgramOptionsAccepted = invalidProgramOptionsResult.success;
              secondRangeMonitorConfig = builtins.fromJSON (
                builtins.unsafeDiscardStringContext secondRangeEval.config.environment.etc."vpsadminos/ebpf-livepatch-monitor.json".text
              );
              autoLoadService =
                let
                  service = serviceEval.config.runit.services.ebpf-livepatch;
                in
                {
                  inherit (service) onChange reloadMethod;
                  hasUsr1Control = service ? control && service.control ? usr1;
                  logEnabled = service.log.enable;
                  logSendTo = service.log.sendTo;
                  runUsesPinnedGeneration =
                    lib.hasInfix "activating pinned generation" service.run
                    && lib.hasInfix "sleep inf" service.run;
                  usr1ActivatesPinnedGeneration =
                    service ? control
                    && service.control ? usr1
                    && lib.hasInfix "ebpf-livepatch-reload" service.control.usr1;
                  finishPreservesPinnedHandoff =
                    lib.hasInfix "preserve-pins-on-finish" service.finish
                    && lib.hasInfix "programs detached" service.finish;
                };
            };
          }
        NIX
      end

      describe 'eBPF livepatch registry' do
        it 'has unique program names' do
          names = @facts.fetch('registry').fetch('allProgramNames')

          expect(names.uniq).to eq(names)
        end

        it 'defines required metadata for every program' do
          @facts.fetch('registry').fetch('programs').each do |program|
            expect(program.fetch('hasName')).to be(true)
            expect(program.fetch('hasDescription')).to be(true)
            expect(program.fetch('hasKernelRanges')).to be(true)
            expect(program.fetch('hasEnable')).to be(true)
            expect(program.fetch('hasBpfPrograms')).to be(true)
            expect(program.fetch('hasLinkFields')).to be(true)
          end
        end

        it 'defines valid kernel-visible BPF program names' do
          @facts.fetch('registry').fetch('programs').each do |program|
            expect(program.fetch('bpfProgramNamesValid')).to be(true)
            expect(program.fetch('bpfProgramNamesUnique')).to be(true)
          end
        end

        it 'defines valid BPF skeleton link field names' do
          @facts.fetch('registry').fetch('programs').each do |program|
            expect(program.fetch('linkFieldsValid')).to be(true)
            expect(program.fetch('linkFieldsUnique')).to be(true)
          end
        end

        it 'validates BPF names using kernel object name rules' do
          validation = @facts.fetch('registry').fetch('bpfNameValidation')

          expect(validation.fetch('valid')).to be(true)
          expect(validation.fetch('empty')).to be(false)
          expect(validation.fetch('tooLong')).to be(false)
          expect(validation.fetch('invalidCharacter')).to be(false)
        end

        it 'validates link fields as C identifiers' do
          validation = @facts.fetch('registry').fetch('linkFieldValidation')

          expect(validation.fetch('valid')).to be(true)
          expect(validation.fetch('empty')).to be(false)
          expect(validation.fetch('startsWithDigit')).to be(false)
          expect(validation.fetch('dotted')).to be(false)
        end

        it 'defines valid kernel ranges' do
          @facts.fetch('registry').fetch('programs').each do |program|
            expect(program.fetch('kernelRangesValid')).to be(true)
          end
        end

        it 'rejects empty, malformed, unsorted, and overlapping kernel ranges' do
          validation = @facts.fetch('registry').fetch('kernelRangeValidation')

          expect(validation.fetch('valid')).to be(true)
          expect(validation.fetch('empty')).to be(false)
          expect(validation.fetch('missingSince')).to be(false)
          expect(validation.fetch('unknownAttribute')).to be(false)
          expect(validation.fetch('nonNumeric')).to be(false)
          expect(validation.fetch('whitespace')).to be(false)
          expect(validation.fetch('reversed')).to be(false)
          expect(validation.fetch('unsorted')).to be(false)
          expect(validation.fetch('overlapping')).to be(false)
          expect(validation.fetch('adjacent')).to be(true)
          expect(validation.fetch('unboundedBeforeLast')).to be(false)
        end

        it 'has a BPF source file for every program' do
          @facts.fetch('registry').fetch('programs').each do |program|
            expect(program.fetch('sourceExists')).to be(true)
          end
        end
      end

      describe 'kernel version rules' do
        it 'excludes kernels below sinceKernel' do
          expect(@facts.fetch('synthetic').fetch('belowSince')).to be(false)
        end

        it 'includes kernels equal to sinceKernel' do
          expect(@facts.fetch('synthetic').fetch('atSince')).to be(true)
        end

        it 'excludes kernels equal to untilKernel' do
          expect(@facts.fetch('synthetic').fetch('atUntil')).to be(false)
        end

        it 'excludes kernels between ranges' do
          synthetic = @facts.fetch('synthetic')

          expect(synthetic.fetch('inGap')).to be(false)
          expect(synthetic.fetch('belowSecondSince')).to be(false)
        end

        it 'matches a second kernel range with the same boundary semantics' do
          synthetic = @facts.fetch('synthetic')

          expect(synthetic.fetch('atSecondSince')).to be(true)
          expect(synthetic.fetch('beforeSecondUntil')).to be(true)
          expect(synthetic.fetch('atSecondUntil')).to be(false)
          expect(synthetic.fetch('secondRange')).to eq(
            'sinceKernel' => '6.18.3',
            'untilKernel' => '6.18.7'
          )
        end

        it 'supports patch versions in untilKernel' do
          synthetic = @facts.fetch('synthetic')

          expect(synthetic.fetch('patchBeforeUntil')).to be(true)
          expect(synthetic.fetch('patchAtUntil')).to be(false)
        end
      end

      describe 'default programs' do
        it 'excludes ptrace_mm_guard before kernel 5.7' do
          expect(@facts.fetch('defaults').fetch('beforeSince')).not_to include('ptrace_mm_guard')
        end

        it 'includes ptrace_mm_guard at kernel 5.7' do
          expect(@facts.fetch('defaults').fetch('atSince')).to include('ptrace_mm_guard')
        end

        it 'includes ptrace_mm_guard through kernel 6.12.88' do
          expect(@facts.fetch('defaults').fetch('beforePtraceUntil')).to include('ptrace_mm_guard')
        end

        it 'excludes ptrace_mm_guard at kernel 6.12.89' do
          expect(@facts.fetch('defaults').fetch('atPtraceUntil')).not_to include('ptrace_mm_guard')
        end

        it 'matches ptrace_mm_guard default to current kernel eligibility' do
          defaults = @facts.fetch('defaults')

          expect(defaults.fetch('current').include?('ptrace_mm_guard')).to eq(
            defaults.fetch('currentHasPtrace')
          )
        end

        it 'includes cifs_spnego_guard through kernel 6.12.91' do
          defaults = @facts.fetch('defaults')

          expect(defaults.fetch('beforeCifsUntil')).to include('cifs_spnego_guard')
        end

        it 'excludes cifs_spnego_guard at kernel 6.12.92' do
          defaults = @facts.fetch('defaults')

          expect(defaults.fetch('atCifsUntil')).not_to include('cifs_spnego_guard')
        end

        it 'matches cifs_spnego_guard default to current kernel eligibility' do
          defaults = @facts.fetch('defaults')

          expect(defaults.fetch('current').include?('cifs_spnego_guard')).to eq(
            defaults.fetch('currentHasCifsSpnego')
          )
        end

        it 'does not include disabled programs by default' do
          defaults = @facts.fetch('defaults').fetch('current')

          expect(defaults).not_to include('override_uname')
          expect(defaults).not_to include('lsm_example')
        end
      end

      describe 'service module options' do
        it 'documents multiple ranges with inclusive lower and exclusive upper bounds' do
          description = @facts.fetch('module').fetch('optionDescription').gsub(/\s+/, ' ')

          expect(description).to include('one or more kernelRanges')
          expect(description).to include('sinceKernel')
          expect(description).to include('sinceKernel is an inclusive lower bound')
          expect(description).to include('untilKernel')
          expect(description).to include('untilKernel is an exclusive upper bound')
          expect(description).to include('matches one of its ranges')
        end

        it 'documents BPF program name requirements in assertions' do
          messages = @facts.fetch('module').fetch('assertionMessages')
          message = messages.find { |v| v.include?('BPF program names must be') }

          expect(message).to include('non-empty')
          expect(message).to include('at most 15 characters')
          expect(message).to include("ASCII letters, digits, '_', or '.'")
        end

        it 'defaults to registry-enabled programs for the current kernel' do
          mod = @facts.fetch('module')

          expect(mod.fetch('defaultPrograms')).to eq(mod.fetch('registryDefaultPrograms'))
        end

        it 'allows eligible disabled-by-default programs to be selected manually' do
          mod = @facts.fetch('module')

          expect(mod.fetch('manualDisabledPrograms')).to eq(['lsm_example'])
          expect(mod.fetch('manualDisabledFailures')).to eq([])
        end

        it 'exports monitoring metadata for selected programs' do
          config = @facts.fetch('module').fetch('manualDisabledMonitorConfig')
          program = config.fetch('programs').first

          expect(config.fetch('bpftool')).to end_with('/bin/bpftool')
          expect(program.fetch('name')).to eq('lsm_example')
          expect(program.fetch('sinceKernel')).to eq('5.7')
          expect(program.fetch('untilKernel')).to be_nil
          expect(program.fetch('bpfPrograms')).to eq(
            %w[lsm_cred_prep lsm_task_prctl lsm_sysctl]
          )
          expect(program.fetch('revision')).to eq('test-vpsadminos-revision')
          expect(program.fetch('digest')).to match(/\A[0-9a-f]{64}\z/)
        end

        it 'exports the matching range for monitoring metadata' do
          config = @facts.fetch('module').fetch('secondRangeMonitorConfig')
          program = config.fetch('programs').first

          expect(config.fetch('kernelVersion')).to eq('6.18.6')
          expect(program.fetch('name')).to eq('lsm_example')
          expect(program.fetch('sinceKernel')).to eq('6.18.3')
          expect(program.fetch('untilKernel')).to eq('6.18.7')
        end

        it 'reloads the autoload service using a pinned generation handoff' do
          service = @facts.fetch('module').fetch('autoLoadService')

          expect(service.fetch('onChange')).to eq('reload')
          expect(service.fetch('reloadMethod')).to eq('1')
          expect(service.fetch('hasUsr1Control')).to be(true)
          expect(service.fetch('logEnabled')).to be(true)
          expect(service.fetch('logSendTo')).to eq('127.0.0.1')
          expect(service.fetch('runUsesPinnedGeneration')).to be(true)
          expect(service.fetch('usr1ActivatesPinnedGeneration')).to be(true)
          expect(service.fetch('finishPreservesPinnedHandoff')).to be(true)
        end

        it 'rejects unknown per-program options' do
          mod = @facts.fetch('module')

          expect(mod.fetch('invalidProgramOptionsAccepted')).to be(false)
        end

        it 'rejects unknown manual programs' do
          messages = @facts.fetch('module').fetch('unknownFailures')

          expect(messages.length).to eq(1)
          expect(messages.first).to include('unknown eBPF livepatch program')
          expect(messages.first).to include('missing_program')
        end

        it 'rejects invalid registry ranges even when defaults omit the program' do
          messages = @facts.fetch('module').fetch('invalidRegistryFailures')

          expect(messages.length).to eq(1)
          expect(messages.first).to include('registry contains program(s)')
          expect(messages.first).to include('lsm_example')
          expect(messages.first).to include('accepts only sinceKernel and untilKernel')
        end

        it 'rejects out-of-range manual programs' do
          messages = @facts.fetch('module').fetch('outOfRangeFailures')

          expect(messages.length).to eq(1)
          expect(messages.first).to include('not available for kernel 5.6')
          expect(messages.first).to include('ptrace_mm_guard')
          expect(messages.first).to include('kernel >= 5.7 (inclusive)')
        end

        it 'rejects manual programs at their exclusive upper bound' do
          messages = @facts.fetch('module').fetch('atUpperBoundFailures')

          expect(messages.length).to eq(1)
          expect(messages.first).to include('not available for kernel 6.12.89')
          expect(messages.first).to include('ptrace_mm_guard')
          expect(messages.first).to include('kernel >= 5.7 (inclusive)')
          expect(messages.first).to include('and < 6.12.89 (exclusive)')
        end

        it 'rejects cifs_spnego_guard at its exclusive upper bound' do
          messages = @facts.fetch('module').fetch('cifsAtUpperBoundFailures')

          expect(messages.length).to eq(1)
          expect(messages.first).to include('not available for kernel 6.12.92')
          expect(messages.first).to include('cifs_spnego_guard')
          expect(messages.first).to include('and < 6.12.92 (exclusive)')
        end
      end
    '';
  }
)
