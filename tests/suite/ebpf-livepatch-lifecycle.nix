import ../make-test.nix (
  { pkgs }:
  let
    livepatchConfig = programs: {
      services.ebpf-livepatch = {
        enable = true;
        inherit programs;
      };
    };

    switchedSystem =
      programs:
      (import ../../os (
        {
          importedPkgs = pkgs;
          system = pkgs.system;
          modules = [
            ../configs/vpsadminos/base.nix
            (livepatchConfig programs)
          ];
        }
        // (pkgs.vpsadminosTestFrameworkInputs or { })
      )).config.system.build.toplevel;

    initialPrograms = {
      lsm_example = { };
      override_uname = { };
    };
    retainedPrograms = {
      lsm_example = { };
    };
    retainedSystem = switchedSystem retainedPrograms;
    emptySystem = switchedSystem { };
  in
  {
    name = "ebpf-livepatch-lifecycle";

    description = ''
      Test eBPF livepatch reconciliation across configuration switches
    '';

    tags = [ "ci" ];

    machine = import ../machines/vpsadminos/with-empty.nix {
      inherit pkgs;
      config = {
        imports = [ (livepatchConfig initialPrograms) ];
        system.extraDependencies = [
          retainedSystem
          emptySystem
        ];
      };
    };

    testScript = ''
      require 'json'
      require 'shellwords'

      BPFTOOL = ${builtins.toJSON "${pkgs.bpftools}/bin/bpftool"}
      PIN_ROOT = '/sys/fs/bpf/vpsadminos/ebpf-livepatch/generations'
      STATE_DIR = '/run/ebpf-livepatch'
      INITIAL_PINS = %w[
        lsm_example__lsm_cred_prep
        lsm_example__lsm_sysctl
        lsm_example__lsm_task_prctl
        override_uname__uname_fentry
        override_uname__uname_fexit
      ].freeze
      RETAINED_PINS = %w[
        lsm_example__lsm_cred_prep
        lsm_example__lsm_sysctl
        lsm_example__lsm_task_prctl
      ].freeze

      def current_generation
        _, output = machine.succeeds("cat #{STATE_DIR}/current-generation")
        output.strip
      end

      def generation_pins(generation = current_generation)
        path = File.join(PIN_ROOT, generation)
        _, output = machine.succeeds(
          "find #{Shellwords.escape(path)} -mindepth 1 -maxdepth 1 " \
          "-printf '%f\\n' | sort"
        )
        output.lines.map(&:strip)
      end

      def link_ids(generation = current_generation)
        generation_pins(generation).to_h do |pin|
          path = File.join(PIN_ROOT, generation, pin)
          _, output = machine.succeeds(
            "#{BPFTOOL} -j link show pinned #{Shellwords.escape(path)}"
          )
          [pin, JSON.parse(output).fetch('id')]
        end
      end

      def expect_single_generation(generation)
        _, output = machine.succeeds(
          "find #{PIN_ROOT} -mindepth 1 -maxdepth 1 -type d -printf '%f\\n'"
        )
        expect(output.lines.map(&:strip)).to eq([generation])
        machine.succeeds("test -s #{STATE_DIR}/#{generation}.attached-at")
      end

      def wait_for_generation_replacement(old_generation)
        machine.wait_until_succeeds(
          "test \"$(cat #{STATE_DIR}/current-generation)\" != " \
          "#{Shellwords.escape(old_generation)} && " \
          "test ! -e #{Shellwords.escape(File.join(PIN_ROOT, old_generation))}"
        )
        current_generation
      end

      def clear_service_log
        machine.succeeds(
          "find /var/log/ebpf-livepatch -type f -exec truncate -s 0 {} +"
        )
      end

      before(:context) do
        machine.start
        machine.wait_for_service('ebpf-livepatch')
      end

      describe 'eBPF livepatch configuration changes', order: :defined do
        it 'starts with the complete configured generation' do
          generation = current_generation

          expect(generation_pins(generation)).to eq(INITIAL_PINS.sort)
          expect_single_generation(generation)
        end

        it 'removes every link from superseded generations' do
          old_generation = current_generation
          old_ids = link_ids(old_generation)

          _, output = machine.succeeds(
            '${retainedSystem}/bin/switch-to-configuration test'
          )

          expect(output).to include('> sv 1 ebpf-livepatch')
          generation = wait_for_generation_replacement(old_generation)
          expect(generation_pins(generation)).to eq(RETAINED_PINS.sort)
          expect_single_generation(generation)

          new_ids = link_ids(generation)
          expect(new_ids.values & old_ids.values).to be_empty
          old_ids.each_value do |id|
            machine.fails("#{BPFTOOL} link show id #{id}")
          end
        end

        it 'keeps the current generation when activation fails' do
          generation = current_generation
          ids = link_ids(generation)
          clear_service_log

          machine.succeeds(<<~CMD)
            mount --bind #{PIN_ROOT} #{PIN_ROOT}
            mount -o remount,bind,ro #{PIN_ROOT}
          CMD

          _, output = machine.succeeds(
            '${emptySystem}/bin/switch-to-configuration test'
          )

          expect(output).to include('> sv 1 ebpf-livepatch')
          machine.wait_until_succeeds(
            "grep -R -Fq 'unable to activate pinned generation; " \
            "keeping current programs' /var/log/ebpf-livepatch"
          )
          expect(current_generation).to eq(generation)
          expect(generation_pins(generation)).to eq(RETAINED_PINS.sort)
          expect(link_ids(generation)).to eq(ids)

          machine.succeeds(<<~CMD)
            mount -o remount,bind,rw #{PIN_ROOT}
            umount #{PIN_ROOT}
          CMD
        end

        it 'supports an authoritative empty program set' do
          old_generation = current_generation
          old_ids = link_ids(old_generation)

          machine.succeeds('sv 1 ebpf-livepatch')

          generation = wait_for_generation_replacement(old_generation)
          expect(generation_pins(generation)).to be_empty
          expect_single_generation(generation)
          old_ids.each_value do |id|
            machine.fails("#{BPFTOOL} link show id #{id}")
          end
        end
      end
    '';
  }
)
