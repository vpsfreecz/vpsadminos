{ pkgs, common }:
let
  testcts = [
    "kloadavg1"
    "kloadavg2"
  ];
  testctsRuby = builtins.concatStringsSep " " testcts;

  genLoad = pkgs.writeScript "genload.py" ''
    #!${pkgs.python3}/bin/python3
    import os, signal, time, platform, ctypes, sys

    arch = platform.machine()
    VFORK_NR = {
        "x86_64": 58, "i386": 190, "i686": 190,
        "aarch64": 220, "armv7l": 189, "armv6l": 189
    }.get(arch)
    if VFORK_NR is None:
        sys.exit(f"Unsupported arch {arch}")

    libc = ctypes.CDLL(None, use_errno=True)
    libc.syscall.restype = ctypes.c_long

    children = []

    def make_blocker():
        pid = os.fork()
        if pid: return pid
        kid = libc.syscall(VFORK_NR)
        if kid == 0:
            while True: time.sleep(3600)
        else:
            os.waitpid(kid, 0)
            os._exit(0)

    def make_cpu_worker():
        pid = os.fork()
        if pid: return pid
        while True: pass

    n_block = int(os.environ.get('N_BLOCKED', '2'))
    n_run   = int(os.environ.get('N_RUNNING', '2'))
    print(f"genload: {n_block} blockers + {n_run} cpu loops")

    for _ in range(n_block): children.append(make_blocker())
    for _ in range(n_run):   children.append(make_cpu_worker())

    def cleanup(sig, frame):
        for c in children:
            try: os.kill(c, signal.SIGKILL)
            except ProcessLookupError: pass
        for c in children:
            try: os.waitpid(c, 0)
            except ChildProcessError: pass
        sys.exit(0)

    signal.signal(signal.SIGTERM, cleanup)
    signal.signal(signal.SIGINT,  cleanup)

    while True: time.sleep(3600)
  '';

  mkContainer = {
    user = "kloadavg";

    autostart.enable = false;

    startMenu.enable = false;

    config = {
      environment.systemPackages = [
        common.compatSysinfo
        pkgs.busybox
        pkgs.sysinfo-to-json
      ];

      systemd.services.genload = {
        serviceConfig = {
          EnvironmentFile = "-/run/genload.conf";
          Type = "simple";
          ExecStart = genLoad;
        };
      };
    };
  };
in
{
  machineConfig =
    { ... }:
    {
      osctl.pools.tank = {
        users.kloadavg = {
          uidMap = [ "0:500000:65536" ];
          gidMap = [ "0:500000:65536" ];
        };

        containers = {
          kloadavg1 = mkContainer;
          kloadavg2 = mkContainer;
        };
      };
    };

  testScripts = {
    loadavg = {
      description = ''
        Test load average virtualization
      '';

      script = common.useMachine 2 + ''
        SCHED_LOAD_SHIFT = 11
        SYSINFO_LOAD_SHIFT = 16
        SYSINFO_TO_SCHED_SHIFT = SYSINFO_LOAD_SHIFT - SCHED_LOAD_SHIFT
        SCHED_FIXED_ONE = 1 << SCHED_LOAD_SHIFT
        PROC_LOAD_ROUNDING = SCHED_FIXED_ONE / 200

        testcts = %w[${testctsRuby}]
        loadavgs = %w[1m 5m 15m]

        def self.start_genload(testct, n_blocked:, n_running:)
          machine.succeeds("osctl ct exec #{testct} sh -c 'echo -e \"N_BLOCKED=#{n_blocked}\nN_RUNNING=#{n_running}\" > /run/genload.conf'")
          machine.succeeds("osctl ct exec #{testct} systemctl restart genload")
        end

        def self.stop_genload(testct)
          machine.succeeds("osctl ct exec #{testct} systemctl stop genload >/dev/null 2>&1 || true")
        end

        def self.parse_loadavg_fields(content)
          content.strip.split.first(3)
        end

        def self.parse_loadavg(content)
          parse_loadavg_fields(content).map(&:to_f)
        end

        def self.read_host_load_fields
          parse_loadavg_fields(machine.succeeds('cat /proc/loadavg')[1])
        end

        def self.read_container_load_fields(testct)
          parse_loadavg_fields(
            machine.succeeds(
              "osctl ct exec #{testct} cat /proc/loadavg"
            )[1]
          )
        end

        def self.read_host_load
          read_host_load_fields.map(&:to_f)
        end

        def self.read_container_load(testct)
          read_container_load_fields(testct).map(&:to_f)
        end

        def self.host_sysinfo
          JSON.parse(machine.succeeds('sysinfo-to-json')[1])
        end

        def self.container_sysinfo(testct)
          JSON.parse(machine.succeeds("osctl ct exec #{testct} sysinfo-to-json")[1])
        end

        def self.raw_sysinfo_loads_to_proc(raw_loads)
          divisor = 1 << SYSINFO_TO_SCHED_SHIFT

          raw_loads.map do |raw|
            expect(raw).to be_a(Integer)
            expect(raw % divisor).to eq(0)

            sched_load = raw >> SYSINFO_TO_SCHED_SHIFT
            rounded = sched_load + PROC_LOAD_ROUNDING
            integer = rounded >> SCHED_LOAD_SHIFT
            fraction =
              ((rounded & (SCHED_FIXED_ONE - 1)) * 100) >>
                SCHED_LOAD_SHIFT

            format('%d.%02d', integer, fraction)
          end
        end

        def self.sysinfo_load_snapshot(testct:, binary:)
          script =
            'printf "PROC_BEFORE "; cat /proc/loadavg; ' \
              "printf \"SYSINFO \"; #{binary}; " \
              'printf "PROC_AFTER "; cat /proc/loadavg'
          command =
            if testct
              "osctl ct exec #{testct} sh -c '#{script}'"
            else
              "sh -c '#{script}'"
            end

          _, output = machine.succeeds(command)
          lines = output.lines.map(&:strip)
          proc_before_line =
            lines.detect { |line| line.start_with?('PROC_BEFORE ') }
          sysinfo_line = lines.detect { |line| line.start_with?('SYSINFO ') }
          proc_after_line =
            lines.detect { |line| line.start_with?('PROC_AFTER ') }

          return { output: output } unless (
            proc_before_line && sysinfo_line && proc_after_line
          )

          proc_before =
            parse_loadavg_fields(
              proc_before_line.delete_prefix('PROC_BEFORE ')
            )
          sysinfo = JSON.parse(sysinfo_line.delete_prefix('SYSINFO '))
          proc_after =
            parse_loadavg_fields(
              proc_after_line.delete_prefix('PROC_AFTER ')
            )

          {
            proc_before: proc_before,
            proc_after: proc_after,
            sysinfo_proc:
              raw_sysinfo_loads_to_proc(sysinfo.fetch('loads_raw')),
            sysinfo: sysinfo
          }
        end

        def self.stable_sysinfo_load_snapshot(
          name,
          testct:,
          binary:,
          expected_word_bits:,
          timeout: 30,
          interval: 0.2
        )
          deadline = Time.now + timeout
          last_snapshot = nil

          loop do
            last_snapshot =
              sysinfo_load_snapshot(testct: testct, binary: binary)

            if (
              last_snapshot[:proc_before] &&
              last_snapshot[:proc_before] == last_snapshot[:proc_after] &&
              last_snapshot[:sysinfo_proc] == last_snapshot[:proc_before]
            )
              sysinfo = last_snapshot.fetch(:sysinfo)
              if expected_word_bits
                expect(sysinfo.fetch('word_bits')).to eq(expected_word_bits)
              else
                expected_floats =
                  sysinfo.fetch('loads_raw').map do |raw|
                    raw / (1 << SYSINFO_LOAD_SHIFT).to_f
                  end

                expect(sysinfo.fetch('loads')).to eq(expected_floats)
              end

              return last_snapshot
            end

            break if Time.now >= deadline
            sleep(interval)
          end

          fail(
            "#{name} did not produce a stable proc/sysinfo sample " \
              "within #{timeout}s: #{last_snapshot.inspect}"
          )
        end

        def self.stable_load_snapshot(
          name,
          testct: nil,
          timeout: 30,
          interval: 0.2
        )
          compat_binary =
            testct ? 'sysinfo-compat-to-json' : '/scripts/sysinfo-compat-to-json'

          {
            native: stable_sysinfo_load_snapshot(
              "#{name} native",
              testct: testct,
              binary: 'sysinfo-to-json',
              expected_word_bits: nil,
              timeout: timeout,
              interval: interval
            ),
            compat: stable_sysinfo_load_snapshot(
              "#{name} compat",
              testct: testct,
              binary: compat_binary,
              expected_word_bits: 32,
              timeout: timeout,
              interval: interval
            )
          }
        end

        def self.stable_nested_native_load_snapshot(
          name,
          testct,
          timeout: 30,
          interval: 0.2
        )
          deadline = Time.now + timeout
          last_snapshot = nil

          loop do
            unit = "loadavg-snapshot-#{Process.pid}-#{rand(1_000_000)}"
            _, output = machine.succeeds(
              "osctl ct exec #{testct} " \
                "systemd-run --quiet --wait --pipe --collect " \
                "--unit #{unit} /bin/sh -c " \
                "'printf \"PROC_BEFORE \"; " \
                "/run/current-system/sw/bin/cat /proc/loadavg; " \
                "printf \"SYSINFO \"; " \
                "/run/current-system/sw/bin/sysinfo-to-json; " \
                "printf \"PROC_AFTER \"; " \
                "/run/current-system/sw/bin/cat /proc/loadavg'"
            )

            lines = output.lines.map(&:strip)
            proc_before_line =
              lines.detect { |line| line.start_with?('PROC_BEFORE ') }
            native_line =
              lines.detect { |line| line.start_with?('SYSINFO ') }
            proc_after_line =
              lines.detect { |line| line.start_with?('PROC_AFTER ') }

            if proc_before_line && native_line && proc_after_line
              proc_before =
                parse_loadavg_fields(
                  proc_before_line.delete_prefix('PROC_BEFORE ')
                )
              native =
                JSON.parse(native_line.delete_prefix('SYSINFO '))
              proc_after =
                parse_loadavg_fields(
                  proc_after_line.delete_prefix('PROC_AFTER ')
                )
              native_proc =
                raw_sysinfo_loads_to_proc(native.fetch('loads_raw'))

              last_snapshot = {
                proc_before: proc_before,
                proc_after: proc_after,
                native_proc: native_proc,
                native: native
              }

              if proc_before == proc_after && native_proc == proc_before
                return last_snapshot
              end
            else
              last_snapshot = { output: output }
            end

            break if Time.now >= deadline
            sleep(interval)
          end

          fail(
            "#{name} did not produce a stable nested-service sample " \
              "within #{timeout}s: #{last_snapshot.inspect}"
          )
        end

        def self.busybox_loadavg(testct)
          _, output = machine.succeeds(
            "osctl ct exec #{testct} env LC_ALL=C busybox uptime"
          )
          pattern = Regexp.new(
            'load averages?:\s*' \
              '([0-9]+\.[0-9]+),\s*' \
              '([0-9]+\.[0-9]+),\s*' \
              '([0-9]+\.[0-9]+)'
          )
          match = output.match(pattern)

          fail "unable to parse BusyBox uptime output: #{output.inspect}" unless match

          match.captures.map(&:to_f)
        end

        def self.wait_for_load_at_least(name, target_load, timeout: 60, interval: 5)
          deadline = Time.now + timeout
          cur_load = nil

          loop do
            cur_load = yield

            return cur_load if cur_load >= target_load
            break if Time.now >= deadline

            sleep(interval)
          end

          fail "#{name} did not reach #{target_load} within #{timeout}s, last load was #{cur_load.inspect}"
        end

        configure_examples do |config|
          config.default_order = :defined
        end

        before(:suite) do
          ensure_kernel_machine
          push_sysinfo_script

          testcts.each do |testct|
            machine.wait_until_succeeds(
              "sv check ct-tank-#{testct}",
              timeout: 10 * 60
            )
            machine.succeeds(
              "osctl ct start --wait 0 #{testct}",
              timeout: 60
            )
            machine.wait_for_osctl_container(testct, timeout: 5 * 60)
            machine.wait_until_succeeds("osctl ct exec #{testct} systemctl is-system-running")
            stop_genload(testct)
          end

          sleep(30) # time for the loadavg to drop after start or a previous run
        end

        after(:suite) do
          testcts.each do |testct|
            stop_genload(testct)
          end
        end

        describe 'loadavg' do
          testcts.each do |testct|
            context "initial ABI view in #{testct}" do
              it 'matches proc through native and compat sysinfo' do
                stable_load_snapshot(
                  "initial load in #{testct}",
                  testct: testct
                )
              end

              it 'reports low load through BusyBox uptime' do
                busybox_loadavg(testct).each do |load|
                  expect(load).to be < 1
                end
              end
            end
          end

          testcts[0..0].each do |testct|
            context "in container #{testct}" do
              loadavgs.each_with_index do |lavg, i|
                it "has low #{lavg} load in /proc/loadavg on start" do
                  expect(read_container_load(testct)[i]).to be < 1
                end

                it "has low #{lavg} load in sysinfo()" do
                  expect(container_sysinfo(testct)['loads'][i]).to be < 1
                end
              end

              increase_ratio = 8.0
              decrease_ratio = 4.0

              [
                { n_blocked: 16, n_running: 0  },
                { n_blocked: 0,  n_running: 16 },
                { n_blocked: 8,  n_running: 8  }
              ].each do |load_config|
                context "loadavg with blocked=#{load_config[:n_blocked]} running=#{load_config[:n_running]}" do
                  before(:context) do
                    start_genload(testct, **load_config)
                  end

                  loadavgs.each_with_index do |lavg, i|
                    it "increases #{lavg} load inside" do
                      last_load = nil
                      cur_load = nil
                      target_load = load_config.values.sum / increase_ratio
                      seconds = [60, 300, 900][i]
                      interval = 5

                      (seconds * 2 / interval).times do
                        cur_load = read_container_load(testct)[i]

                        if last_load
                          expect(cur_load).to be >= last_load
                        end

                        last_load = cur_load
                        sleep(interval)

                        break if cur_load >= target_load
                      end

                      expect(cur_load).to be >= target_load
                    end
                  end

                  loadavgs.each_with_index do |lavg, i|
                    it "saturates #{lavg} load inside /proc/loadavg" do
                      ct_load = read_container_load(testct)
                      expect(ct_load[i]).to be >= (load_config.values.sum / increase_ratio)
                    end

                    it "saturates #{lavg} load in sysinfo()" do
                      expect(container_sysinfo(testct)['loads'][i]).to be >= (load_config.values.sum / increase_ratio)
                    end
                  end

                  (testcts - [testct]).each do |other_ct|
                    loadavgs.each_with_index do |lavg, i|
                      it "does not affect #{lavg} load in other container #{other_ct} in /proc/loadavg" do
                        other_load = read_container_load(other_ct)
                        expect(other_load[i]).to be < 1
                      end

                      it "does not affect #{lavg} load in other container #{other_ct} in sysinfo()" do
                        expect(container_sysinfo(other_ct)['loads'][i]).to be < 1
                      end
                    end
                  end

                  loadavgs.each_with_index do |lavg, i|
                    it "is included in #{lavg} host load in /proc/loadavg" do
                      target_load = load_config.values.sum / increase_ratio

                      host_load = wait_for_load_at_least("host #{lavg} load in /proc/loadavg", target_load) do
                        read_host_load[i]
                      end

                      expect(host_load).to be >= target_load
                    end

                    it "is included in #{lavg} host load in sysinfo()" do
                      target_load = load_config.values.sum / increase_ratio

                      host_load = wait_for_load_at_least("host #{lavg} load in sysinfo()", target_load) do
                        host_sysinfo['loads'][i]
                      end

                      expect(host_load).to be >= target_load
                    end
                  end

                  it 'matches proc through native and compat sysinfo while loaded' do
                    stable_load_snapshot(
                      "loaded view in #{testct}",
                      testct: testct
                    )
                  end

                  it 'uses the top-level namespace from a nested service cgroup' do
                    stable_nested_native_load_snapshot(
                      "nested service view in #{testct}",
                      testct
                    )
                  end

                  it 'reports the loaded view through BusyBox uptime' do
                    target_load =
                      load_config.values.sum / increase_ratio

                    busybox_loadavg(testct).each do |load|
                      expect(load).to be >= target_load
                    end
                  end

                  (testcts - [testct]).each do |other_ct|
                    it "keeps proc and both syscall ABIs isolated in #{other_ct}" do
                      stable_load_snapshot(
                        "sibling view in #{other_ct}",
                        testct: other_ct
                      )
                    end

                    it "keeps BusyBox uptime isolated in #{other_ct}" do
                      busybox_loadavg(other_ct).each do |load|
                        expect(load).to be < 1
                      end
                    end
                  end

                  it 'keeps host proc and syscall ABIs on the global fallback' do
                    stable_load_snapshot('host global load')
                  end

                  it 'stops genload' do
                    stop_genload(testct)
                  end

                  loadavgs.each_with_index do |lavg, i|
                    it "decreases #{lavg} load inside /proc/loadavg" do
                      last_load = nil
                      cur_load = nil
                      target_load = load_config.values.sum / decrease_ratio
                      seconds = [60, 300, 900][i]
                      interval = 5

                      (seconds * 2 / interval).times do
                        cur_load = read_container_load(testct)[i]

                        if last_load
                          expect(cur_load).to be <= last_load
                        end

                        last_load = cur_load
                        sleep(interval)

                        break if cur_load <= target_load
                      end

                      expect(cur_load).to be <= target_load
                    end
                  end

                  loadavgs.each_with_index do |lavg, i|
                    it "decreases #{lavg} load in sysinfo()" do
                      expect(container_sysinfo(testct)['loads'][i]).to be <= (load_config.values.sum / decrease_ratio)
                    end
                  end

                  it 'matches proc and both syscall ABIs after bounded decay' do
                    stable_load_snapshot(
                      "decayed view in #{testct}",
                      testct: testct
                    )
                  end

                  it 'restarts container' do
                    machine.succeeds("osctl ct restart #{testct}")
                    sleep(30)
                  end

                  loadavgs.each_with_index do |lavg, i|
                    it "resets #{lavg} load in /proc/loadavg on container restart" do
                      expect(read_container_load(testct)[i]).to be < 1
                    end

                    it "resets #{lavg} load in sysinfo() on container restart" do
                      expect(container_sysinfo(testct)['loads'][i]).to be < 1
                    end
                  end

                  it 'matches proc and both syscall ABIs after restart' do
                    stable_load_snapshot(
                      "restarted view in #{testct}",
                      testct: testct
                    )
                  end

                  it 'reports the reset view through BusyBox uptime' do
                    busybox_loadavg(testct).each do |load|
                      expect(load).to be < 1
                    end
                  end
                end
              end

              context '/proc/loadavg' do
                before(:context) do
                  @ct_loadavg = machine.succeeds("osctl ct exec #{testct} cat /proc/loadavg")[1].strip
                end

                it 'has 5 columns' do
                  expect(@ct_loadavg.split.length).to eq(5)
                end

                loadavgs.each_with_index do |lavg, i|
                  it "has #{lavg} load" do
                    expect(@ct_loadavg.split[i].to_f).to be >= 0
                  end
                end

                it 'has runnable entities' do
                  expect(@ct_loadavg.split[3].split('/')[0].to_i).to be >= 1
                end

                it 'has scheduling entities' do
                  expect(@ct_loadavg.split[3].split('/')[1].to_i).to be >= 1
                end

                it 'has last pid' do
                  expect(@ct_loadavg.split[4].to_i).to be >= 1
                end
              end
            end
          end

          context 'from the host' do
            before(:context) do
              testcts.each_with_index do |testct, i|
                start_genload(testct, n_blocked: (i + 1) * 2, n_running: 0)
              end
            end

            after(:context) do
              testcts.each do |testct|
                machine.succeeds("osctl ct restart #{testct}")
              end

              sleep(30)
            end

            testcts.each_with_index do |testct, i|
              it "#{testct} has expected 1m load" do
                interval = 5
                ct_load = nil
                target_load = i + 1

                (90 / interval).times do
                  ct_load = machine.osctl_json("ct show #{testct}")['loadavg']
                  break if ct_load[0] >= target_load

                  sleep(interval)
                end

                expect(ct_load[0]).to be >= target_load
              end
            end

            context 'in /proc/vpsadminos/loadavg' do
              it 'has expected entries' do
                _, output = machine.succeeds('cat /proc/vpsadminos/loadavg')
                expect(output.strip.split("\n").length).to be >= testcts.length
              end

              testcts.each_with_index do |testct, i|
                context "entry for #{testct}" do
                  before(:context) do
                    @loadavg_entry = []
                  end

                  it 'exists' do
                    init_pid = machine.osctl_json("ct show #{testct}")['init_pid'].to_i
                    cgns_link = machine.succeeds("readlink /proc/#{init_pid}/ns/cgroup")[1].strip

                    rx = /cgroup:\[(\d+)\]/

                    expect(cgns_link).to match(rx)

                    raise 'invalid cgns link' if rx !~ cgns_link

                    cgns_id = ::Regexp.last_match(1).to_i

                    expect(cgns_id).to be > 0

                    load_lines = machine.succeeds('cat /proc/vpsadminos/loadavg')[1].strip.split("\n")

                    load_line = load_lines.detect { |line| line.start_with?("#{cgns_id}\t") }
                    expect(load_line).to start_with(cgns_id.to_s)

                    @loadavg_entry = load_line.split
                  end

                  it 'has 5 columns' do
                    expect(@loadavg_entry.length).to eq(5)
                  end

                  loadavgs.each_with_index do |lavg, i|
                    it "has #{lavg} load" do
                      # @loadavg_entry[0] is cgroup namespace id, hence i + 1
                      expect(@loadavg_entry[i + 1].to_f).to be > 0
                    end
                  end

                  it 'has runnable processes' do
                    expect(@loadavg_entry[4].split('/')[0].to_i).to be > 0
                  end

                  it 'has scheduling entities' do
                    expect(@loadavg_entry[4].split('/')[1].to_i).to be > 0
                  end
                end
              end
            end
          end
        end
      '';
    };
  };
}
