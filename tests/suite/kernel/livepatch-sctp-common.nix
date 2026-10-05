{
  baseline ? false,
}:
# Acceptance case for the restored SCTP retransmission-scan correction.
#
# Question this test answers: with the payload's corrected
# sctp_assoc_update_retran_path() active, does a real DEL-IP ASCONF
# transaction complete while every transport of the receiving association is
# SCTP_UNCONFIRMED and the removed transport is the armed retran_path?  The
# defective body spins forever in that cycle (the node22 class); the corrected
# body breaks when the scan returns to retran_path, so the host must stay
# alive and the transaction must return.
#
# The all-unconfirmed/armed state is deterministic: the test probe writes the
# transports unconfirmed and points retran_path at the tail transport (the one
# the transaction removes), so the case does not depend on timing or on which
# path heartbeats happen to have confirmed.
#
# Run (test-runner, from the OS tree):
#   VPSADMINOS_LIVEPATCH_SINGLE_SERIES_MODULE=<store>/lib/modules/6.12.95/extra/livepatch_7.ko \
#     ./test-runner.sh test -f --stop-on-failure -j 1 -t ci \
#     --state-dir <state>/run kernel/livepatch-sctp-hostile
import ../../make-test.nix (
  { pkgs }:
  let
    moduleEnv = builtins.getEnv "VPSADMINOS_LIVEPATCH_SINGLE_SERIES_MODULE";
    qualifying = !baseline && moduleEnv == "";
    selectedModule =
      if qualifying then builtins.getEnv "VPSADMINOS_LIVEPATCH_CORRECTED_MODULE" else moduleEnv;
    expectedSha256 = (import ../../fixtures/livepatch { inherit pkgs; }).correctedSha256;
    moduleNameEnv = builtins.getEnv "VPSADMINOS_LIVEPATCH_MODULE_NAME";
    moduleName = if moduleNameEnv == "" then "livepatch_7" else moduleNameEnv;

    sctpHostileDriver = pkgs.stdenv.mkDerivation {
      pname = "livepatch-sctp-hostile-driver";
      version = "1";
      src = ./livepatch-sctp-hostile;

      buildInputs = [ pkgs.lksctp-tools ];
      dontConfigure = true;

      buildPhase = ''
        "$CC" -std=gnu11 -O2 -Wall -Wextra -Werror \
          -o sctp_hostile sctp_hostile.c -lsctp
      '';

      installPhase = ''
        install -Dm755 sctp_hostile "$out/bin/sctp_hostile"
      '';
    };
  in
  assert baseline || selectedModule != "";
  assert !baseline || (moduleEnv == "" && moduleNameEnv == "");
  assert
    !qualifying
    || (
      moduleName == "livepatch_7"
      && builtins.hashFile "sha256" (builtins.storePath selectedModule) == expectedSha256
    );
  {
    name = if baseline then "kernel-livepatch-sctp-baseline" else "kernel-livepatch-sctp-hostile";
    description =
      if baseline then
        "Unpatched SCTP: establish and restore the hostile scan precondition"
      else
        "SCTP livepatch: hostile DEL-IP over an all-unconfirmed association "
        + "completes and the host stays alive";
    tags =
      if baseline then
        [ "livepatch-amd" ]
      else if qualifying then
        [
          "livepatch-amd"
          "livepatch-intel"
        ]
      else
        [ "ci" ];

    machine = import ../../machines/vpsadminos/with-empty.nix {
      inherit pkgs;
      config =
        {
          lib,
          pkgs,
          ...
        }:
        let
          # Build the probe with the frozen boot kernel's GCC plugin ABI.
          kernel = (import ../../../os/packages/linux/boot-6.12.95.nix).kernel;
          probeModule = kernel.stdenv.mkDerivation {
            pname = "livepatch-sctp-hostile-probe";
            version = kernel.modDirVersion;
            src = ./livepatch-6.12.95;

            nativeBuildInputs = kernel.nativeBuildInputs ++ [ pkgs.gnumake ];
            hardeningDisable = [
              "bindnow"
              "format"
              "fortify"
              "stackprotector"
              "pic"
            ];

            buildPhase = ''
              make -C ${kernel.dev}/lib/modules/${kernel.modDirVersion}/build \
                M="$PWD" modules
            '';

            installPhase = ''
              install -Dm644 livepatch_test_probe.ko \
                "$out/lib/modules/${kernel.modDirVersion}/extra/livepatch_test_probe.ko"
            '';
          };
        in
        {
          imports = [ ../../configs/vpsadminos/livepatch-6.12.95-boot-base.nix ];
          boot.kernelVersion = lib.mkForce "6.12.95";

          # The test arms the probe and loads the module itself.
          services.live-patches.enable = lib.mkForce false;

          environment.systemPackages = [
            pkgs.binutils
            pkgs.kmod
            pkgs.procps
            pkgs.util-linux
          ];

          environment.etc = {
            "livepatch-sctp-hostile/probe.ko".source =
              "${probeModule}/lib/modules/${kernel.modDirVersion}/extra/livepatch_test_probe.ko";
            "livepatch-sctp-hostile/sctp_hostile".source = "${sctpHostileDriver}/bin/sctp_hostile";
          }
          // lib.optionalAttrs (!baseline) {
            "livepatch-sctp-hostile/module.ko".source = builtins.storePath selectedModule;
          };
        };
    };

    testScript = ''
      SCTP_STATE = "/run/livepatch-sctp-hostile"
      SCTP_CYCLES = ${if qualifying then "100" else "1"}
      MODULE_NAME = ${builtins.toJSON moduleName}
      MODULE_SHA256 = ${if qualifying then builtins.toJSON expectedSha256 else "nil"}
      MODULE_FILE = "/etc/livepatch-sctp-hostile/module.ko"
      PROBE_FILE = "/etc/livepatch-sctp-hostile/probe.ko"
      HOSTILE_DRIVER = "/etc/livepatch-sctp-hostile/sctp_hostile"
      PROBE_PARAMETERS = "/sys/module/livepatch_test_probe/parameters"
      PATCH_DIR = "/sys/kernel/livepatch/#{MODULE_NAME}"

      def symbol_address(machine, symbol, module_name = nil)
        module_filter =
          if module_name
            "&& $4 == \"[#{module_name}]\""
          else
            "&& NF == 3"
          end
        _, output = machine.succeeds(
          "awk '$3 == \"#{symbol}\" #{module_filter} " \
          "{ print \"0x\" $1; exit }' /proc/kallsyms"
        )
        address = output.strip
        raise "kernel symbol not found: #{symbol} (#{module_name})" if address.empty?

        address
      end

      def fixed_body_hits(machine)
        machine.succeeds("cat #{PROBE_PARAMETERS}/probe_hits")[1].strip.to_i
      end

      before(:suite) do
        machine.start
        machine.wait_until_online
        machine.succeeds("test \"$(uname -r)\" = 6.12.95")
        machine.succeeds("modprobe sctp")
        unless MODULE_SHA256.nil?
          machine.succeeds("test \"$(sha256sum #{MODULE_FILE} | cut -d' ' -f1)\" = #{MODULE_SHA256}")
        end
      end

    ''
    + (
      if baseline then
        ''
          def assert_unpatched_sctp_baseline
            machine.all_succeed(
              'test "$(uname -r)" = 6.12.95',
              'test -d /sys/kernel/livepatch',
              'test -z "$(find /sys/kernel/livepatch -mindepth 1 -maxdepth 1 -print -quit)"',
              'test -z "$(find /sys/module -maxdepth 1 -name "livepatch_[0-9]*" -print -quit)"',
              'uname -a; cat /proc/modules; ls -la /sys/kernel/livepatch',
            )
          end

          describe 'Unpatched SCTP retransmission-scan precondition' do
            it 'establishes the native all-unconfirmed precondition and restores it without a hostile scan' do
              puts 'VULNERABLE BASELINE: precondition only; not a v7 target pass or reproduced native hang'
              assert_unpatched_sctp_baseline
              start = Integer(machine.succeeds('dmesg | wc -l')[1].strip) + 1
              machine.all_succeed(
                "mkdir #{SCTP_STATE}",
                "insmod #{PROBE_FILE}",
                'sysctl -w net.sctp.addip_enable=1 net.sctp.addip_noauth_enable=1',
                "( #{HOSTILE_DRIVER} #{SCTP_STATE}; echo $? > #{SCTP_STATE}/exit ) " \
                  "> #{SCTP_STATE}/driver.log 2>&1 &",
              )
              machine.wait_until_succeeds("test -e #{SCTP_STATE}/assoc", timeout: 60)
              address = symbol_address(machine, 'sctp_process_asconf', 'sctp')
              machine.all_succeed(
                "echo #{address} > #{PROBE_PARAMETERS}/probe_address",
                "echo 1 > #{PROBE_PARAMETERS}/probe_capture_args",
                "touch #{SCTP_STATE}/add",
              )
              machine.wait_until_succeeds(
                "test \"$(cat #{PROBE_PARAMETERS}/probe_hits)\" -gt 0 && " \
                  "test \"$(cat #{PROBE_PARAMETERS}/probe_arg0)\" != 0", timeout: 60
              )
              asoc = machine.succeeds("cat #{PROBE_PARAMETERS}/probe_arg0")[1].strip
              machine.all_succeed(
                "echo 0 > #{PROBE_PARAMETERS}/probe_capture_args",
                "echo 0 > #{PROBE_PARAMETERS}/probe_address",
                "echo #{asoc} > #{PROBE_PARAMETERS}/sctp_asoc_address",
              )
              machine.wait_until_succeeds(
                "test \"$(cat #{PROBE_PARAMETERS}/sctp_transport_count)\" -ge 2", timeout: 60
              )
              machine.all_succeed(
                "test ! -e #{SCTP_STATE}/exit",
                "echo 1 > #{PROBE_PARAMETERS}/sctp_baseline_check",
              )
              established = Integer(machine.succeeds("cat #{PROBE_PARAMETERS}/sctp_baseline_transports")[1].strip)
              transports = Integer(machine.succeeds("cat #{PROBE_PARAMETERS}/sctp_transport_count")[1].strip)
              unconfirmed = Integer(machine.succeeds("cat #{PROBE_PARAMETERS}/sctp_unconfirmed_count")[1].strip)
              expect(established).to be >= 2
              expect(established).to eq(transports)
              expect(unconfirmed).to be < transports
              puts "native precondition established under lock for #{established} transports; original states/path restored"

              # Only an ordinary DEL-IP runs now, after restoring the active path.
              machine.succeeds("touch #{SCTP_STATE}/arm")
              machine.wait_until_succeeds("test -e #{SCTP_STATE}/rem-sent", timeout: 60)
              machine.wait_until_succeeds("test -e #{SCTP_STATE}/done", timeout: 60)
              machine.all_succeed("test -e #{SCTP_STATE}/health-ok", "touch #{SCTP_STATE}/release")
              machine.wait_until_succeeds("test -e #{SCTP_STATE}/exit", timeout: 60)
              machine.all_succeed(
                "test \"$(cat #{SCTP_STATE}/exit)\" = 0",
                "cat #{SCTP_STATE}/driver.log",
                "echo 0 > #{PROBE_PARAMETERS}/sctp_asoc_address",
                'rmmod livepatch_test_probe',
              )
              assert_unpatched_sctp_baseline
              dmesg = machine.succeeds("dmesg | tail -n +#{start}")[1]
              expect(dmesg).not_to match(/BUG:|WARNING:|Oops:|general protection fault|[Kk]ernel panic|KASAN|UBSAN|blocked for more than|soft lockup|hard LOCKUP|(?:rcu|RCU).*stall/)
            end
          end
        ''
      else
        ''
          describe 'SCTP retransmission-path livepatch under a hostile ASCONF transaction' do
            it "completes #{SCTP_CYCLES} hostile DEL-IP cycles and keeps the host alive" do
              machine.fails("test -d /sys/module/#{MODULE_NAME}")
              machine.fails("test -d /sys/module/livepatch_test_probe")
              machine.succeeds("mkdir #{SCTP_STATE}")
              dmesg_start = machine.succeeds("dmesg | wc -l")[1].to_i + 1

              machine.succeeds("insmod #{PROBE_FILE}")
              machine.succeeds("test -d #{PROBE_PARAMETERS}")

              # Forward leg: load the payload under test.
              machine.succeeds("insmod #{MODULE_FILE}", timeout: 300)
              deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 300
              loop do
                enabled = machine.succeeds("cat #{PATCH_DIR}/enabled 2>&1 || true")[1].strip
                transition = machine.succeeds("cat #{PATCH_DIR}/transition 2>&1 || true")[1].strip
                puts "post-insmod: enabled=#{enabled.inspect} transition=#{transition.inspect}"
                break if enabled == '1' && transition == '0'
                raise "forward leg did not settle: enabled=#{enabled.inspect} transition=#{transition.inspect}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
                sleep 5
              end

              # Section names are a linker representation and may be coalesced.
              # Resolve the replacement body in this loaded module; the probe
              # below requires every hostile cycle to execute that exact body.
              replacement_address =
                symbol_address(machine, 'sctp_assoc_update_retran_path', MODULE_NAME)
              puts "SCTP replacement body address: #{replacement_address}"
              expect(Integer(replacement_address)).to be > 0

              # ADD-IP is disabled by default (net.sctp.addip_enable=0 and
              # addip_noauth_enable=0), and sctp_send_asconf_add_ip() returns
              # early while the endpoint has it off: sctp_bindx(ADD_ADDR) then only
              # adds the address locally and never puts an ASCONF on the wire.  The
              # endpoint picks the setting up at socket creation, so enable it
              # before the driver opens its sockets.
              machine.succeeds(
                "sh -c 'echo 1 > /proc/sys/net/sctp/addip_enable; " \
                "echo 1 > /proc/sys/net/sctp/addip_noauth_enable'"
              )

              SCTP_CYCLES.times do |cycle|
                state = "#{SCTP_STATE}/cycle-#{cycle + 1}"
                machine.succeeds("mkdir #{state}")
                puts "SCTP hostile cycle #{cycle + 1}/#{SCTP_CYCLES} begins"
                # Phase 1: loopback association, then a real ASCONF Add-IP.
                machine.succeeds(
                  "( #{HOSTILE_DRIVER} #{state}; echo $? > #{state}/exit ) " \
                  "> #{state}/driver.log 2>&1 & echo $! > #{state}/driver.pid"
                )
                begin
                  machine.wait_until_succeeds("test -e #{state}/assoc", timeout: 60)
                rescue StandardError
                  puts "driver log: #{machine.succeeds("cat #{state}/driver.log 2>/dev/null || true")[1].inspect}"
                  raise
                end

                # Capture the server-side association from its ASCONF processing.
                # The module patches sctp_process_asconf, so the [sctp] copy is
                # klp-held (permanent IPMODIFY ftrace ops) and cannot host the
                # capture kprobe.  Anchor on the livepatch copy -- the live,
                # post-transition code path -- like the phase-2 counter below.
                capture_address = symbol_address(machine, "sctp_process_asconf", MODULE_NAME)
                machine.all_succeed(
                  "sh -c 'echo 0 > #{PROBE_PARAMETERS}/probe_address'",
                  "sh -c 'echo #{capture_address} > #{PROBE_PARAMETERS}/probe_address'",
                  "sh -c 'echo 1 > #{PROBE_PARAMETERS}/probe_capture_args'",
                )
                machine.succeeds("touch #{state}/add")
                machine.wait_until_succeeds(
                  "test \"$(cat #{PROBE_PARAMETERS}/probe_hits)\" -gt 0 && " \
                  "test \"$(cat #{PROBE_PARAMETERS}/probe_arg0)\" != 0",
                  timeout: 60
                )
                asoc = machine.succeeds("cat #{PROBE_PARAMETERS}/probe_arg0")[1].strip
                puts "captured server association: #{asoc}"
                machine.succeeds("sh -c 'echo 0 > #{PROBE_PARAMETERS}/probe_capture_args'")
                machine.succeeds("sh -c 'echo #{asoc} > #{PROBE_PARAMETERS}/sctp_asoc_address'")

                # Arm the wrap: every transport unconfirmed, retran_path at the tail.
                machine.succeeds("sh -c 'echo 1 > #{PROBE_PARAMETERS}/sctp_arm_unconfirmed'")
                unconfirmed = machine.succeeds("cat #{PROBE_PARAMETERS}/sctp_unconfirmed_count")[1].strip
                transports = machine.succeeds("cat #{PROBE_PARAMETERS}/sctp_transport_count")[1].strip
                puts "armed: transports=#{transports} unconfirmed=#{unconfirmed}"
                expect(unconfirmed.to_i).to eq(transports.to_i)
                expect(unconfirmed.to_i).to be >= 2

                # Count entries into the replacement body. This is the phase oracle:
                # the transaction is not accepted unless it executes the corrected
                # function rather than merely completing through another path.
                counter_address =
                  symbol_address(machine, "sctp_assoc_update_retran_path", MODULE_NAME)
                machine.all_succeed(
                  "sh -c 'echo 0 > #{PROBE_PARAMETERS}/probe_address'",
                  "echo 1 > #{PROBE_PARAMETERS}/sctp_check_retran",
                  "sh -c 'echo #{counter_address} > #{PROBE_PARAMETERS}/probe_address'",
                )
                counter_hits = fixed_body_hits(machine)
                hostile_hits = Integer(machine.succeeds("cat #{PROBE_PARAMETERS}/sctp_hostile_hits")[1].strip)
                puts "fixed-body counter armed (hits=#{counter_hits})"

                # Phase 2: the hostile DEL-IP removes the armed retransmission path.
                machine.succeeds("touch #{state}/arm")
                begin
                  machine.wait_until_succeeds("test -e #{state}/rem-sent", timeout: 300)
                  machine.wait_until_succeeds(
                    "test \"$(cat #{PROBE_PARAMETERS}/probe_hits)\" -gt #{counter_hits}",
                    timeout: 300
                  )
                rescue StandardError
                  puts "driver log: #{machine.succeeds("cat #{state}/driver.log 2>/dev/null || true")[1].inspect}"
                  raise
                end
                after = fixed_body_hits(machine)
                puts "fixed-body counter hits after transaction: #{after - counter_hits}"
                expect(after).to be > counter_hits
                hostile_after = Integer(machine.succeeds("cat #{PROBE_PARAMETERS}/sctp_hostile_hits")[1].strip)
                puts "all-unconfirmed scan entries in this cycle: #{hostile_after - hostile_hits}"
                expect(hostile_after).to be > hostile_hits

                # Host liveness and lockup scan.
                machine.succeeds("echo guest-alive", timeout: 60)
                uptime_before = machine.succeeds("cat /proc/uptime")[1].split[0].to_f
                sleep 2
                uptime_after = machine.succeeds("cat /proc/uptime")[1].split[0].to_f
                expect(uptime_after).to be > uptime_before
                lockups = machine.succeeds(
                  "sh -c 'dmesg | tail -n +#{dmesg_start} | grep -iE \"BUG:|WARNING:|Oops:|kernel panic|soft lockup|hard LOCKUP|hung task|blocked for more than|rcu.*stall\" || true'"
                )[1].strip
                puts "lockup scan: #{lockups.inspect}"
                expect(lockups).to eq("")
                machine.wait_until_succeeds(
                  "test -e #{state}/health-ok -o -e #{state}/health-failed",
                  timeout: 60
                )
                health = machine.succeeds(
                  "sh -c 'if test -e #{state}/health-ok; then echo ok; " \
                  "elif test -e #{state}/health-failed; then echo failed; else echo none; fi'"
                )[1].strip
                puts "association health after transaction: #{health}"
                expect(health).to eq("ok")

                # Release the driver; it must exit cleanly.
                machine.all_succeed(
                  "echo 0 > #{PROBE_PARAMETERS}/probe_address",
                  "echo 0 > #{PROBE_PARAMETERS}/sctp_check_retran",
                  "echo 0 > #{PROBE_PARAMETERS}/sctp_asoc_address",
                  "touch #{state}/release"
                )
                machine.wait_until_succeeds("test -e #{state}/exit", timeout: 60)
                machine.succeeds("test \"$(cat #{state}/exit)\" = 0")
                machine.succeeds("cat #{state}/driver.log")
                machine.succeeds("test -e #{state}/done")

                puts "SCTP hostile cycle #{cycle + 1}/#{SCTP_CYCLES} complete"
              end

              # Reverse leg.
              machine.succeeds("sh -c 'echo 0 > #{PATCH_DIR}/enabled'", timeout: 300)
              deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 300
              loop do
                transition = machine.succeeds("cat #{PATCH_DIR}/transition 2>&1 || true")[1].strip
                dir_state = machine.succeeds("test -e #{PATCH_DIR}/enabled && echo present || echo gone")[1].strip
                puts "post-disable: transition=#{transition.inspect} patch_dir=#{dir_state}"
                break if transition == '0' || dir_state == 'gone'
                raise 'reverse leg did not settle' if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
                sleep 5
              end
              machine.succeeds("rmmod #{MODULE_NAME}", timeout: 300)
              machine.fails("test -d /sys/module/#{MODULE_NAME}")
              expect(
                machine.succeeds("test -e #{PATCH_DIR}/enabled && echo present || echo gone")[1].strip
              ).to eq('gone')

              # Probe cleanup.
              machine.succeeds("sh -c 'echo 0 > #{PROBE_PARAMETERS}/sctp_asoc_address'")
              machine.succeeds("rmmod livepatch_test_probe")
            end
          end
        ''
    );
  }
)
