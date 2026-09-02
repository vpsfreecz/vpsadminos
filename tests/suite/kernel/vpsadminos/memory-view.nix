{ common }:
let
  mkMemoryViewScript =
    cgroupsVersion:
    let
      version = toString cgroupsVersion;
      prefix = "kmemv${version}";
    in
    {
      "memory-view-cgroups-v${version}" = {
        description = ''
          Test memory view virtualization with cgroups v${version}
        '';

        script = common.useMachine cgroupsVersion + ''
          def self.parse_meminfo(content)
            content.strip.each_line.to_h do |line|
              # <param>: <value> [kB]
              param, value, _ = line.split
              [param[0..-2], value.to_i]
            end
          end

          def self.parse_sysinfo(content)
            JSON.parse(content)
          end

          # Swap size is in kB and -4 kB from the original value
          def self.bytes_to_swap_size(bytes)
            bytes / 1024 - 4
          end

          def self.cleanup_kernel_memory_swap
            _, output = machine.succeeds("awk 'NR > 1 { print $1 }' /proc/swaps || true")

            output.lines.map(&:strip).each do |dev|
              next unless dev.start_with?('/dev/zram')

              machine.succeeds("swapoff #{dev} >/dev/null 2>&1 || true")
            end

            machine.succeeds('for dev in /dev/zram*; do [ -e "$dev" ] && zramctl --reset "$dev" >/dev/null 2>&1 || true; done')
            machine.succeeds('modprobe -r zram >/dev/null 2>&1 || true')
          end

          def self.container_tests
            context 'without memory limit' do
              testct = get_container_id('${prefix}')

              before(:context) do
                machine.all_succeed(
                  "osctl ct new --distribution alpine #{testct}",
                  "osctl ct netif new bridge --link lxcbr0 #{testct} eth0",
                  "osctl ct start #{testct}"
                )
                machine.wait_until_container_online(testct)
                container_apk(machine, testct, 'add', 'python3', name: "Install Python in #{testct}")
              end

              after(:context) do
                delete_test_container(testct)
              end

              context 'in /proc/meminfo' do
                before(:context) do
                  @host_mem = parse_meminfo(machine.succeeds('cat /proc/meminfo')[1])
                  @ct_mem = parse_meminfo(machine.succeeds("osctl ct exec #{testct} cat /proc/meminfo")[1])
                end

                it 'has the same number of values' do
                  expect(@host_mem.size).to be > 0
                  expect(@host_mem.size).to eq(@ct_mem.size)
                end

                %w[MemTotal SwapTotal].each do |v|
                  it "has the same #{v}" do
                    expect(@host_mem[v]).to eq(@ct_mem[v])
                  end
                end
              end

              context 'in sysinfo()' do
                before(:context) do
                  @host_sys = parse_sysinfo(machine.succeeds('sysinfo-to-json')[1])
                  @ct_sys = parse_sysinfo(machine.succeeds("osctl ct runscript #{testct} /scripts/sysinfo.py")[1])
                end

                %w[totalram totalhigh totalswap freeswap].each do |v|
                  it "has the same #{v}" do
                    expect(@host_sys[v]).to be >= 0
                    expect(@host_sys[v]).to eq(@ct_sys[v])
                  end
                end
              end

              context '/proc/swaps' do
                it 'is the same as on the host' do
                  _, host_swaps = machine.succeeds('cat /proc/swaps')
                  _, ct_swaps = machine.succeeds("osctl ct exec #{testct} cat /proc/swaps")

                  expect(host_swaps).to eq(ct_swaps)
                end
              end
            end

            context 'with memory limit' do
              testcts = {
                '${prefix}-mem256' => [256 * 1024 * 1024, 0],
                '${prefix}-mem512' => [512 * 1024 * 1024, 0],
                '${prefix}-mem256swap128' => [256 * 1024 * 1024, 128 * 1024 * 1024],
                '${prefix}-mem512swap256' => [512 * 1024 * 1024, 256 * 1024 * 1024]
              }

              testcts.each do |testct, (memory_limit, swap_limit)|
                context "of memory=#{memory_limit / 1024 / 1024}M swap=#{swap_limit / 1024 / 1024}M" do
                  before(:context) do
                    delete_test_container(testct)

                    machine.all_succeed(
                      "osctl ct new --distribution alpine #{testct}",
                      "osctl ct netif new bridge --link lxcbr0 #{testct} eth0",
                      "osctl ct set memory #{testct} #{memory_limit} #{swap_limit > 0 ? swap_limit : ""}",
                      "osctl ct start #{testct}"
                    )
                    machine.wait_until_container_online(testct)
                    container_apk(machine, testct, 'add', 'python3', name: "Install Python in #{testct}")
                  end

                  after(:context) do
                    delete_test_container(testct)
                  end

                  context 'in /proc/meminfo' do
                    before(:context) do
                      @host_mem = parse_meminfo(machine.succeeds('cat /proc/meminfo')[1])
                      @ct_mem = parse_meminfo(machine.succeeds("osctl ct exec #{testct} cat /proc/meminfo")[1])
                      @mem_total = memory_limit / 1024
                      @swap_total = swap_limit / 1024
                    end

                    it 'sees subset of values' do
                      expect(@ct_mem.size).to be > 0
                      expect(@ct_mem.size).to be < @host_mem.size
                    end

                    it 'has virtualized MemTotal' do
                      expect(@ct_mem['MemTotal']).to eq(@mem_total)
                    end

                    %w[SwapTotal SwapFree].each do |v|
                      it "has virtualized #{v}" do
                        expect(@ct_mem[v]).to eq(@swap_total)
                      end
                    end

                    %w[MemFree MemAvailable Buffers Cached Shmem AnonPages Mapped].each do |v|
                      it "has virtualized #{v}" do
                        expect(@ct_mem[v]).to be >= 0
                        expect(@ct_mem[v]).to be < @mem_total
                        expect(@ct_mem[v]).to be < @host_mem[v]
                      end
                    end

                    %w[SReclaimable SUnreclaim SwapCached].each do |v|
                      it "has virtualized #{v}" do
                        expect(@ct_mem[v]).to eq(0)
                      end
                    end

                    %w[CommitLimit Committed_AS VmallocTotal VmallocUsed VmallocChunk Percpu].each do |v|
                      it "does not contain #{v}" do
                        expect(@ct_mem.has_key?(v)).to be(false)
                      end
                    end
                  end

                  context 'in sysinfo()' do
                    before(:context) do
                      @host_sys = parse_sysinfo(machine.succeeds('sysinfo-to-json')[1])
                      @ct_sys = parse_sysinfo(machine.succeeds("osctl ct runscript #{testct} /scripts/sysinfo.py")[1])
                    end

                    it 'has virtualized totalram' do
                      expect(@ct_sys['totalram']).to eq(memory_limit)
                    end

                    it "has virtualized freeram" do
                      expect(@ct_sys['freeram']).to be > 0
                      expect(@ct_sys['freeram']).to be < @ct_sys['totalram']
                      expect(@ct_sys['freeram']).to be < @host_sys['freeram']
                    end

                    %w[totalswap freeswap].each do |v|
                      it "has virtualized #{v}" do
                        expect(@ct_sys[v]).to eq(swap_limit)
                      end
                    end

                    it 'has virtualized totalhigh' do
                      expect(@ct_sys['totalhigh']).to eq(@ct_sys['totalram'])
                    end

                    it "has virtualized freehigh" do
                      expect(@ct_sys['freehigh']).to eq(@ct_sys['freeram'])
                    end

                    %w[freeram sharedram bufferram].each do |v|
                      it "has virtualized #{v}" do
                        if v == 'bufferram'
                          pending('https://github.com/vpsfreecz/vpsadminos/issues/77')
                        end

                        expect(@ct_sys[v]).to be >= 0
                        expect(@ct_sys[v]).to be < memory_limit
                        expect(@ct_sys[v]).to be < @host_sys[v]
                      end
                    end
                  end

                  context '/proc/swaps' do
                    before(:context) do
                      _, output = machine.succeeds("osctl ct exec #{testct} cat /proc/swaps")
                      @swap_lines = output.strip.split("\n")
                    end

                    if swap_limit > 0
                      it 'has virtual swap device' do
                        expect(@swap_lines.count).to eq(2)
                        expect(@swap_lines.first).to start_with('Filename')
                      end

                      it 'has virtual swap device with expected size' do
                        pending('https://github.com/vpsfreecz/vpsadminos/issues/76')
                        expect(@swap_lines[1].split).to eq(%W[virtual virtual #{bytes_to_swap_size(swap_limit)} 0 -1])
                      end
                    else
                      it 'is empty' do
                        expect(@swap_lines.count).to eq(1)
                        expect(@swap_lines.first).to start_with('Filename')
                      end
                    end
                  end
                end
              end
            end
          end

          before(:suite) do
            ensure_kernel_machine
            cleanup_containers_with_prefix('${prefix}')
            cleanup_kernel_memory_swap
            push_sysinfo_script
          end

          after(:suite) do
            cleanup_containers_with_prefix('${prefix}')
            cleanup_kernel_memory_swap
          end

          describe 'memory view within container without swap device' do
            it 'does not have a swap device on the host' do
              _, output = machine.succeeds('cat /proc/swaps')
              lines = output.strip.split("\n")

              expect(lines.count).to eq(1)
              expect(lines.first).to start_with('Filename')
            end

            container_tests
          end

          describe 'memory view in container with swap device on the host' do
            before(:context) do
              @swap_size = 1 * 1024 * 1024

              machine.succeeds('modprobe zram')

              @zram_device = machine.succeeds("zramctl --find --size #{@swap_size}")[1].strip

              machine.all_succeed(
                "mkswap #{@zram_device}",
                "swapon #{@zram_device}"
              )
            end

            after(:context) do
              machine.all_succeed(
                "swapoff #{@zram_device}",
                "zramctl --reset #{@zram_device}",
                'modprobe -r zram'
              )
            end

            it 'has swap device on the host' do
              _, output = machine.succeeds('cat /proc/swaps')
              lines = output.strip.split("\n")

              expect(lines.count).to eq(2)
              expect(lines.first).to start_with('Filename')

              expect(lines[1].split).to eq(%W[#{@zram_device} partition #{bytes_to_swap_size(@swap_size)} 0 -2])
            end

            container_tests
          end
        '';
      };
    };
in
(mkMemoryViewScript 1) // (mkMemoryViewScript 2)
