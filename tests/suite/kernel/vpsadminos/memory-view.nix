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

          # A real swap device reserves its first page for the swap header.
          def self.physical_swap_size_kb(bytes)
            bytes / 1024 - 4
          end

          # Synthetic virtual rows have no swap header and expose full capacity.
          def self.virtual_swap_size_kb(bytes)
            bytes / 1024
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
                ct_apk_add(testct, 'python3')
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

                %w[MemTotal SwapTotal Buffers].each do |v|
                  it "has the same #{v}" do
                    expect(@host_mem[v]).to eq(@ct_mem[v])
                  end
                end
              end

              context 'in sysinfo()' do
                before(:context) do
                  @host_sys = parse_sysinfo(machine.succeeds('sysinfo-to-json')[1])
                  @ct_sys = parse_sysinfo(machine.succeeds("osctl ct runscript #{testct} /scripts/sysinfo.py")[1])
                  @host_compat = parse_sysinfo(
                    machine.succeeds('/scripts/sysinfo-compat-to-json')[1]
                  )
                  @ct_compat = parse_sysinfo(
                    machine.succeeds(
                      "osctl ct runscript #{testct} /scripts/sysinfo-compat-to-json"
                    )[1]
                  )
                end

                %w[totalram totalhigh totalswap freeswap bufferram].each do |v|
                  it "has the same #{v}" do
                    expect(@host_sys[v]).to be >= 0
                    expect(@host_sys[v]).to eq(@ct_sys[v])
                  end
                end

                it 'preserves the compat sysinfo buffer value' do
                  expect(@host_compat['word_bits']).to eq(32)
                  expect(@ct_compat['word_bits']).to eq(32)
                  expect(@ct_compat['bufferram']).to eq(@host_compat['bufferram'])
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
                '${prefix}-mem256' => [256 * 1024 * 1024, 0, :zero],
                '${prefix}-mem512' => [512 * 1024 * 1024, 0, :zero],
                '${prefix}-mem256swap128' => [
                  256 * 1024 * 1024,
                  128 * 1024 * 1024,
                  :finite
                ],
                '${prefix}-mem512swap256' => [
                  512 * 1024 * 1024,
                  256 * 1024 * 1024,
                  :finite
                ],
                '${prefix}-mem256swapmax' => [
                  256 * 1024 * 1024,
                  nil,
                  :unlimited
                ]
              }

              testcts.each do |testct, (memory_limit, swap_limit, swap_mode)|
                swap_description =
                  swap_mode == :unlimited ? 'unlimited' : "#{swap_limit / 1024 / 1024}M"

                context "of memory=#{memory_limit / 1024 / 1024}M swap=#{swap_description}" do
                  before(:context) do
                    delete_test_container(testct)

                    machine.all_succeed(
                      "osctl ct new --distribution alpine #{testct}",
                      "osctl ct netif new bridge --link lxcbr0 #{testct} eth0",
                      "osctl ct set memory #{testct} #{memory_limit} " \
                        "#{swap_limit && swap_limit > 0 ? swap_limit : ""}"
                    )

                    if swap_mode == :unlimited
                      ${
                        if cgroupsVersion == 2 then
                          ''
                            machine.succeeds(
                              "osctl ct cgparams set -v 2 #{testct} " \
                                "memory.swap.max max"
                            )
                          ''
                        else
                          ''
                            _, @unlimited_swap_value = machine.succeeds(
                              'cat /run/osctl/cgroup/memory/memory.memsw.limit_in_bytes'
                            )
                            @unlimited_swap_value = @unlimited_swap_value.strip
                            machine.succeeds(
                              "osctl ct cgparams set -v 1 #{testct} " \
                                "memory.memsw.limit_in_bytes #{@unlimited_swap_value}"
                            )
                          ''
                      }
                    end

                    machine.succeeds("osctl ct start #{testct}")
                    machine.wait_until_container_online(testct)
                    ct_apk_add(testct, 'python3')
                    machine.succeeds(
                      "osctl ct exec #{testct} sh -c " \
                        "'dd if=/dev/zero of=/tmp/cache-probe bs=1M count=8 " \
                        ">/dev/null 2>&1 && cat /tmp/cache-probe >/dev/null'"
                    )
                  end

                  after(:context) do
                    delete_test_container(testct)
                  end

                  context 'in /proc/meminfo' do
                    before(:context) do
                      @host_mem = parse_meminfo(machine.succeeds('cat /proc/meminfo')[1])
                      @ct_mem = parse_meminfo(machine.succeeds("osctl ct exec #{testct} cat /proc/meminfo")[1])
                      @mem_total = memory_limit / 1024
                      @swap_total =
                        swap_mode == :unlimited ? @host_mem['SwapTotal'] : swap_limit / 1024
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

                    it 'reports no attributable block buffers' do
                      expect(@ct_mem['Buffers']).to eq(0)
                    end

                    it 'keeps file cache separate from block buffers' do
                      expect(@ct_mem['Cached']).to be > 0
                      expect(@ct_mem['Cached']).to be < @mem_total
                    end

                    %w[MemFree MemAvailable Shmem AnonPages Mapped].each do |v|
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
                      @ct_mem = parse_meminfo(
                        machine.succeeds("osctl ct exec #{testct} cat /proc/meminfo")[1]
                      )
                      @ct_compat = parse_sysinfo(
                        machine.succeeds(
                          "osctl ct runscript #{testct} " \
                            "/scripts/sysinfo-compat-to-json"
                        )[1]
                      )
                      @expected_swap_bytes =
                        swap_mode == :unlimited ? @host_sys['totalswap'] : swap_limit
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
                        expect(@ct_sys[v]).to eq(@expected_swap_bytes)
                        expect(@ct_compat[v]).to eq(@expected_swap_bytes)
                      end
                    end

                    it 'has virtualized totalhigh' do
                      expect(@ct_sys['totalhigh']).to eq(@ct_sys['totalram'])
                    end

                    it "has virtualized freehigh" do
                      expect(@ct_sys['freehigh']).to eq(@ct_sys['freeram'])
                    end

                    %w[freeram sharedram].each do |v|
                      it "has virtualized #{v}" do
                        expect(@ct_sys[v]).to be >= 0
                        expect(@ct_sys[v]).to be < memory_limit
                      end
                    end

                    it 'reports no attributable block buffers' do
                      expect(@ct_sys['bufferram']).to eq(0)
                      expect(@ct_compat['word_bits']).to eq(32)
                      expect(@ct_compat['bufferram']).to eq(0)
                      expect(@ct_mem['Buffers']).to eq(0)
                      expect(@ct_mem['Cached']).to be > 0
                    end
                  end

                  context '/proc/swaps' do
                    before(:context) do
                      @host_swap_total_kb =
                        parse_meminfo(machine.succeeds('cat /proc/meminfo')[1])['SwapTotal']
                      _, output = machine.succeeds("osctl ct exec #{testct} cat /proc/swaps")
                      @swap_lines = output.strip.split("\n")
                    end

                    if swap_mode == :finite
                      it 'has virtual swap device' do
                        expect(@swap_lines.count).to eq(2)
                        expect(@swap_lines.first).to start_with('Filename')
                      end

                      it 'has virtual swap device with expected size' do
                        expect(@swap_lines[1].split).to eq(
                          %W[virtual virtual #{virtual_swap_size_kb(swap_limit)} 0 -1]
                        )
                      end
                    elsif swap_mode == :unlimited
                      it 'uses host swap capacity when the controller is unlimited' do
                        if @host_swap_total_kb > 0
                          expect(@swap_lines.count).to eq(2)
                          expect(@swap_lines[1].split).to eq(
                            %W[virtual virtual #{@host_swap_total_kb} 0 -1]
                          )
                        else
                          expect(@swap_lines.count).to eq(1)
                        end
                      end

                      it 'keeps the controller in its native unlimited state' do
                        ${
                          if cgroupsVersion == 2 then
                            ''
                              _, value = machine.succeeds(
                                "osctl ct exec #{testct} " \
                                  "cat /sys/fs/cgroup/memory.swap.max"
                              )
                              expect(value.strip).to eq('max')
                            ''
                          else
                            ''
                              _, value = machine.succeeds(
                                "osctl ct exec #{testct} " \
                                  "cat /sys/fs/cgroup/memory/memory.memsw.limit_in_bytes"
                              )
                              expect(value.strip).to eq(@unlimited_swap_value)
                            ''
                        }
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

              expect(lines[1].split).to eq(
                %W[#{@zram_device} partition #{physical_swap_size_kb(@swap_size)} 0 -2]
              )
            end

            container_tests
          end
        '';
      };
    };
in
(mkMemoryViewScript 1) // (mkMemoryViewScript 2)
