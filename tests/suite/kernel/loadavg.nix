import ../../make-test.nix ({ pkgs }:
let
  genLoad = pkgs.writeScript "genload.py" ''
    #!${pkgs.python3}/bin/python3
    import os, signal, time, platform, ctypes, sys

    # ---- constants & helpers --------------------------------------
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

    def make_blocker():                 # uninterruptible D‑state
        pid = os.fork()
        if pid: return pid
        kid = libc.syscall(VFORK_NR)
        if kid == 0:                    # tiny child
            while True: time.sleep(3600)
        else:
            os.waitpid(kid, 0)
            os._exit(0)

    def make_cpu_worker():              # busy loop
        pid = os.fork()
        if pid: return pid
        while True: pass

    # ---- read counts from argv -------------------------------------
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
    user = "testuser";

    autostart.enable = true;

    startMenu.enable = false;

    config =
      { config, ... }:
      {
        environment.systemPackages = with pkgs; [
          sysinfo-to-json
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
in {
  name = "kernel-loadavg";

  description = ''
    Test load average virtualization
  '';

  tags = [ "ci" ];

  machine = import ../../machines/with-tank.nix {
    inherit pkgs;
    config =
      { config, ... }:
      {
        environment.systemPackages = with pkgs; [
          sysinfo-to-json
        ];

        osctl.pools.tank = {
          users.testuser = {
            uidMap = [ "0:500000:65536" ];
            gidMap = [ "0:500000:65536" ];
          };

          containers = {
            testct1 = mkContainer;
            testct2 = mkContainer;
          };
        };
      };
  };

  testScript = ''
    testcts = %w[testct1 testct2]
    loadavgs = %w[1m 5m 15m]

    start_genload = proc do |testct, n_blocked:, n_running:|
      machine.succeeds("osctl ct exec #{testct} sh -c 'echo -e \"N_BLOCKED=#{n_blocked}\nN_RUNNING=#{n_running}\" > /run/genload.conf'")
      machine.succeeds("osctl ct exec #{testct} systemctl restart genload")
    end

    stop_genload = proc do |testct|
      machine.succeeds("osctl ct exec #{testct} systemctl stop genload")
    end

    parse_loadavg = proc do |content|
      content.strip.split[0..2].map(&:to_f)
    end

    read_host_load = proc do
      parse_loadavg.call(machine.succeeds('cat /proc/loadavg')[1])
    end

    read_container_load = proc do |testct|
      parse_loadavg.call(machine.succeeds("osctl ct exec #{testct} cat /proc/loadavg")[1])
    end

    host_sysinfo = proc do
      JSON.parse(machine.succeeds("sysinfo-to-json")[1])
    end

    container_sysinfo = proc do |testct|
      JSON.parse(machine.succeeds("osctl ct exec #{testct} sysinfo-to-json")[1])
    end

    configure_examples do |config|
      config.default_order = :defined
    end

    describe 'loadavg' do
      before(:context) do
        machine.start

        testcts.each do |testct|
          machine.wait_for_osctl_container(testct)
          machine.wait_until_succeeds("osctl ct exec #{testct} systemctl is-system-running")
        end

        sleep(30) # time for the loadavg to drop after start
      end

      testcts[0..0].each do |testct|
        context "in container #{testct}" do
          loadavgs.each_with_index do |lavg, i|
            it "has low #{lavg} load in /proc/loadavg on start" do
              expect(read_container_load.call(testct)[i]).to be < 1
            end

            it "has low #{lavg} load in sysinfo()" do
              skip('https://github.com/vpsfreecz/vpsadminos/issues/78')
              expect(container_sysinfo.call(testct)['loads'][i]).to be < 1
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
                start_genload.call(testct, **load_config)
              end

              loadavgs.each_with_index do |lavg, i|
                it "increases #{lavg} load inside" do
                  last_load = nil
                  cur_load = nil
                  target_load = load_config.values.sum / increase_ratio
                  seconds = [60, 300, 900][i]
                  interval = 5

                  (seconds * 2 / interval).times do
                    cur_load = read_container_load.call(testct)[i]

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
                  ct_load = read_container_load.call(testct)
                  expect(ct_load[i]).to be >= (load_config.values.sum / increase_ratio)
                end

                it "saturates #{lavg} load in sysinfo()" do
                  skip('https://github.com/vpsfreecz/vpsadminos/issues/78')
                  expect(container_sysinfo.call(testct)['loads'][i]).to be >= (load_config.values.sum / increase_ratio)
                end
              end

              (testcts - [testct]).each do |other_ct|
                loadavgs.each_with_index do |lavg, i|
                  it "does not affect #{lavg} load in other container #{other_ct} in /proc/loadavg" do
                    other_load = read_container_load.call(other_ct)
                    expect(other_load[i]).to be < 1
                  end

                  it "does not affect #{lavg} load in other container #{other_ct} in sysinfo()" do
                    pending('https://github.com/vpsfreecz/vpsadminos/issues/78')
                    expect(container_sysinfo.call(other_ct)['loads'][i]).to be < 1
                  end
                end
              end

              loadavgs.each_with_index do |lavg, i|
                it "is included in #{lavg} host load in /proc/loadavg" do
                  host_load = read_host_load.call

                  expect(host_load[i]).to be >= (load_config.values.sum / increase_ratio)
                end

                it "is included in #{lavg} host load in sysinfo()" do
                  expect(host_sysinfo.call['loads'][i]).to be >= (load_config.values.sum / increase_ratio)
                end
              end

              it 'stops genload' do
                stop_genload.call(testct)
              end

              loadavgs.each_with_index do |lavg, i|
                it "decreases #{lavg} load inside /proc/loadavg" do
                  last_load = nil
                  cur_load = nil
                  target_load = load_config.values.sum / decrease_ratio
                  seconds = [60, 300, 900][i]
                  interval = 5

                  (seconds * 2 / interval).times do
                    cur_load = read_container_load.call(testct)[i]

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
                  skip('https://github.com/vpsfreecz/vpsadminos/issues/78')
                  expect(container_sysinfo.call(testct)['loads'][i]).to be <= (load_config.values.sum / decrease_ratio)
                end
              end

              it 'restarts container' do
                machine.succeeds("osctl ct restart #{testct}")
                sleep(30)
              end

              loadavgs.each_with_index do |lavg, i|
                it "resets #{lavg} load in /proc/loadavg on container restart" do
                  expect(read_container_load.call(testct)[i]).to be < 1
                end

                it "resets #{lavg} load in sysinfo() on container restart" do
                  skip('https://github.com/vpsfreecz/vpsadminos/issues/78')
                  expect(container_sysinfo.call(testct)['loads'][i]).to be < 1
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
            start_genload.call(testct, n_blocked: (i + 1) * 2, n_running: 0)
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
})
