import ../../make-test.nix (
  { pkgs }:
  let
    correctedModuleEnv = builtins.getEnv "VPSADMINOS_LIVEPATCH_CORRECTED_MODULE";
    correctedSha256Env = builtins.getEnv "VPSADMINOS_LIVEPATCH_CORRECTED_SHA256";
  in
  assert correctedModuleEnv != "";
  assert correctedSha256Env != "";
  let
    correctedModule = builtins.storePath correctedModuleEnv;
    correctedSha256 = builtins.hashFile "sha256" correctedModule;

    perfFlags = pkgs.stdenv.mkDerivation {
      pname = "livepatch-test-perf-flags";
      version = "1";
      src = ./livepatch-perf-v7;

      dontConfigure = true;

      buildPhase = ''
        "$CC" -std=gnu11 -O2 -Wall -Wextra -Werror -pthread \
          -o perf_flags perf_flags.c
        "$CC" -std=gnu11 -O2 -Wall -Wextra -Werror -pthread \
          -o perf_cgroup_migration perf_cgroup_migration.c
      '';

      installPhase = ''
        install -Dm755 perf_flags "$out/bin/perf_flags"
        install -Dm755 perf_cgroup_migration "$out/bin/perf_cgroup_migration"
      '';
    };
  in
  {
    name = "kernel-livepatch-perf-v7";
    description = ''
      Livepatch v7 perf witness rows: real group-leader remove-on-exec ENODEV,
      observational FD_NO_GROUP / FD_NO_GROUP|FD_OUTPUT, bounded exec/open race,
      and cgroup-filtered accounting across small and large taskset moves
    '';
    tags = [
      "ci"
      "livepatch-amd"
      "livepatch-intel"
    ];

    machine = import ../../machines/vpsadminos/with-empty.nix {
      inherit pkgs;
      config =
        { lib, ... }:
        {
          imports = [ ../../configs/vpsadminos/livepatch-6.12.95-boot-base.nix ];
          services.live-patches.enable = false;

          environment.etc = {
            "livepatch-test/corrected.ko".source = correctedModule;
            "livepatch-test/perf-flags".source = "${perfFlags}/bin/perf_flags";
            "livepatch-test/perf-cgroup-migration".source = "${perfFlags}/bin/perf_cgroup_migration";
          };
        };
    };

    testScript = ''
      CORRECTED_MODULE = "/etc/livepatch-test/corrected.ko"
      CORRECTED_NAME = "livepatch_7"
      CORRECTED_SHA256 = ${builtins.toJSON correctedSha256Env}
      PERF_FLAGS = "/etc/livepatch-test/perf-flags"
      PERF_CGROUP_MIGRATION = "/etc/livepatch-test/perf-cgroup-migration"
      PATCH_DIR = "/sys/kernel/livepatch/#{CORRECTED_NAME}"

      before(:suite) do
        machine.start
        machine.wait_until_online
        machine.succeeds(
          "test \"$(sha256sum #{CORRECTED_MODULE} | cut -d' ' -f1)\" = #{CORRECTED_SHA256}",
        )
        machine.succeeds("insmod #{CORRECTED_MODULE}", timeout: 60)
        machine.wait_until_succeeds(
          "test \"$(cat #{PATCH_DIR}/enabled)\" = 1 && " \
            "test \"$(cat #{PATCH_DIR}/transition)\" = 0",
          timeout: 180,
        )
        @dmesg_start = machine.succeeds("dmesg | wc -l")[1].to_i
      end

      after(:suite) do
        machine.execute("rmmod #{CORRECTED_NAME}", timeout: 120)
      end

      describe "perf witnesses over livepatch_7", order: :defined do
        ["small", "large"].each do |size|
          it "moves cgroup-filtered counters with a #{size} taskset" do
            cpus = Integer(machine.succeeds("getconf _NPROCESSORS_ONLN")[1].strip)
            tasks = size == "small" ? 1 : cpus + 1
            groups = %w[a b].map { |suffix| "/sys/fs/cgroup/klp_perf_#{size}_#{suffix}" }
            machine.all_succeed(
              "test -e /sys/fs/cgroup/cgroup.controllers",
              "mkdir #{groups.join(' ')}",
            )
            status, output = machine.execute(
              "#{PERF_CGROUP_MIGRATION} #{groups.join(' ')} #{tasks}",
              timeout: 60,
            )
            cleanup_status, cleanup_output = machine.execute("rmdir #{groups.join(' ')}")
            expect(status).to eq(0), output
            expect(cleanup_status).to eq(0), cleanup_output
            expect(output).to include("cgroup migration tasks=#{tasks} cpus=#{cpus} phases=3 passed")
          end
        end

        it "rejects a sibling attach to a remove-on-exec group leader with ENODEV (P1)" do
          rc, out = machine.execute("#{PERF_FLAGS} p1")
          expect(rc).to eq(0), out
          expect(out).to include("ENODEV")
        end

        it "records the FD_NO_GROUP observation (P3)" do
          rc, out = machine.execute("#{PERF_FLAGS} p3")
          expect(rc).to eq(0), out
          expect(out).to match(/flags=0x1 /)
        end

        it "records the FD_NO_GROUP|FD_OUTPUT observation (P4)" do
          rc, out = machine.execute("#{PERF_FLAGS} p4")
          expect(rc).to eq(0), out
          expect(out).to match(/flags=0x3 /)
        end

        it "survives the bounded exec/open race (P5)" do
          rc, out = machine.execute("#{PERF_FLAGS} p5", timeout: 1080)
          expect(rc).to eq(0), out
          expect(out).to match(/attempts=\d+ enodev=\d+ success=0 other=0 internal=0/)
        end

        it "leaves no kernel fault after the perf rows" do
          output = machine.succeeds("dmesg | tail -n +#{@dmesg_start + 1}")[1]
          expect(output).not_to match(
            /BUG:|kernel BUG at|WARNING:|Oops:|general protection fault|[Kk]ernel panic|Invalid relocation target|disagrees about version|Unknown symbol|blocked for more than|soft lockup|hard LOCKUP|(?:rcu|RCU).*stall/,
          )
        end
      end
    '';
  }
)
