{ common }:
let
  mkTmpfsScript =
    cgroupsVersion:
    let
      version = toString cgroupsVersion;
      prefix = "ktmpfsv${version}";
    in
    {
      "tmpfs-cgroups-v${version}" = {
        description = ''
          Test tmpfs UID/GID and size within containers with cgroups v${version}
        '';

        script = common.useMachine cgroupsVersion + ''
          def self.tmpfs_options_from_host(testct, mountpoint)
            init_pid = machine.osctl_json("ct show #{testct}")['init_pid']

            tmpfs_options(machine.succeeds("cat /proc/#{init_pid}/mountinfo")[1], mountpoint)
          end

          def self.tmpfs_options_from_container(testct, mountpoint)
            tmpfs_options(machine.succeeds("osctl ct exec #{testct} cat /proc/1/mountinfo")[1], mountpoint)
          end

          def self.tmpfs_size_from_container(testct, mountpoint)
            size, inodes = machine.succeeds("osctl ct exec #{testct} findmnt -T #{mountpoint} -nb -o SIZE,INO.TOTAL")[1].strip.split
            [size.to_i, inodes.to_i]
          end

          def self.tmpfs_options(mountinfo_str, mountpoint)
            mountinfo_str.strip.each_line do |line|
              fields = line.split(' ')
              next unless fields[4].gsub("\\040", ' ') == mountpoint   # field 5 = mountpoint

              dash = fields.index('-')                                 # separator
              next if dash.nil? || fields[dash + 1] != 'tmpfs'         # fstype must be tmpfs

              super_opts = fields[(dash + 3)..] || []                  # after fstype & source
              opts = super_opts.join(',').split(',').each_with_object({}) do |o, h|
                k, v = o.split('=', 2)
                case k
                when 'uid', 'gid' then h[k] = v.to_i
                when 'size'       then h[k] = size_to_bytes(v)
                end
              end

              raise "no options found on line #{line.inspect}" if opts.empty?

              return opts
            end

            raise "mountpoint #{mountpoint.inspect} not found in #{mountinfo_str.inspect}"
          end

          def self.size_to_bytes(str)
            return str.to_i if /\A(\d+)(k|m|g)\z/i !~ str

            value = ::Regexp.last_match(1).to_i
            unit = ::Regexp.last_match(2).downcase

            case unit
            when 'k' then value * 1024
            when 'm' then value * 1024**2
            when 'g' then value * 1024**3
            else raise "invalid unit #{unit.inspect}"
            end
          end

          testct = get_container_id('${prefix}')

          limits = [
            [],
            [512 * 1024 * 1024, 0],
            [1024 * 1024 * 1024 , 0],
            [512 * 1024 * 1024, 256 * 1024 * 1024],
            [512 * 1024 * 1024, 1024 * 1024 * 1024]
          ]

          host_root_uid = 700_000 + rand(0..50_000)
          host_root_gid = 800_000 + rand(0..50_000)

          before(:suite) do
            ensure_kernel_machine
            cleanup_containers_with_prefix('${prefix}')

            machine.all_succeed(
              "osctl user new --map-uid 0:#{host_root_uid}:65536 --map-gid 0:#{host_root_gid}:65536 #{testct}",
              "osctl ct new --user #{testct} --distribution alpine #{testct}",
              "osctl ct netif new bridge --link lxcbr0 #{testct} eth0",
              "osctl ct unset start-menu #{testct}",
              "osctl ct start #{testct}"
            )
            machine.wait_until_container_online(testct)
            machine.succeeds("osctl ct exec #{testct} apk add findmnt")
          end

          after(:suite) do
            cleanup_containers_with_prefix('${prefix}')
          end

          limits.each do |memory_limit, swap_limit|
            limits_str =
              if memory_limit
                "memory=#{memory_limit / 1024 / 1024}M swap=#{swap_limit / 1024 / 1024}M"
              else
                'no limits'
              end

            describe "tmpfs in container with #{limits_str}" do
              before(:context) do
                if memory_limit
                  machine.succeeds("osctl ct set memory #{testct} #{memory_limit} #{swap_limit > 0 ? swap_limit : ""}")
                else
                  machine.succeeds("osctl ct unset memory #{testct}")
                end
              end

              {
                'without options' => {},
                'with -o size' => { 'size' => 128 * 1024 * 1024 },
                'with -o inodes' => { 'nr_inodes' => 256 * 1024 * 1024 },
                'with -o uid' => { 'uid' => 1000 },
                'with -o gid' => { 'uid' => 2000 },
                'with -o uid,gid' => { 'uid' => 3000, 'gid' => 4000 }
              }.each do |variant, options|
                context variant do
                  after(:context) do
                    machine.succeeds("osctl ct exec #{testct} umount /mnt/tmpfs >/dev/null 2>&1 || true")
                    machine.succeeds("osctl ct exec #{testct} rmdir /mnt/tmpfs >/dev/null 2>&1 || true")
                  end

                  it 'can be mounted' do
                    options_str =
                      if options.any?
                        "-o #{options.map { |k, v| "#{k}=#{v}" }.join(',')}"
                      else
                        ""
                      end

                    machine.succeeds("osctl ct exec #{testct} umount /mnt/tmpfs >/dev/null 2>&1 || true")
                    machine.succeeds("osctl ct exec #{testct} rm -rf /mnt/tmpfs")

                    machine.all_succeed(
                      "osctl ct exec #{testct} mkdir -p /mnt/tmpfs",
                      "osctl ct exec #{testct} mount -t tmpfs #{options_str} tmpfs /mnt/tmpfs"
                    )
                  end

                  context 'size and inodes' do
                    before(:context) do
                      @tmpfs_size, @tmpfs_inodes = tmpfs_size_from_container(testct, '/mnt/tmpfs')
                      next if memory_limit

                      @host_mem_total = mem_total = machine.succeeds('grep MemTotal: /proc/meminfo')[1].strip.split[1].to_i * 1024
                    end

                    context 'size' do
                      if options['size']
                        it 'has custom size' do
                          expect(@tmpfs_size).to eq(options['size'])
                        end
                      elsif memory_limit
                        it 'has default size set to 50 % of memory limit' do
                          expect(@tmpfs_size).to eq(memory_limit / 2)
                        end
                      else
                        it 'has default size set to 50 % of host memory' do
                          expect(@tmpfs_size).to eq(@host_mem_total / 2).or eq(@host_mem_total / 2 - 2048)
                        end
                      end
                    end

                    context 'inodes' do
                      if options['nr_inodes']
                        it 'has custom nr_inodes' do
                          expect(@tmpfs_inodes).to eq(options['nr_inodes'])
                        end
                      elsif memory_limit
                        it 'has default inodes set with respect to memory limit' do
                          expect(@tmpfs_inodes).to eq(memory_limit / 4096)
                        end
                      else
                        it 'has default inodes set to 1/2 of physical memory pages' do
                          expect(@tmpfs_inodes).to eq(@host_mem_total / 4096 / 2)
                        end
                      end
                    end
                  end

                  context '/proc/1/mountinfo from the inside' do
                    before(:context) do
                      @tmpfs_opts = tmpfs_options_from_container(testct, '/mnt/tmpfs')
                    end

                    expected_uid = options.fetch('uid', 0)
                    expected_gid = options.fetch('gid', 0)

                    it "has uid=#{expected_uid}" do
                      expect(@tmpfs_opts['uid']).to eq(expected_uid)
                    end

                    it "has gid=#{expected_gid}" do
                      expect(@tmpfs_opts['gid']).to eq(expected_gid)
                    end

                    if options['size']
                      it "has size=#{options['size']}" do
                        expect(@tmpfs_opts['size']).to eq(options['size'])
                      end
                    else
                      it 'has no size option' do
                        expect(@tmpfs_opts.has_key?('size')).to be(false)
                      end
                    end
                  end

                  context '/proc/<init_pid>/mountinfo from the host' do
                    before(:context) do
                      @tmpfs_opts = tmpfs_options_from_host(testct, '/mnt/tmpfs')
                    end

                    expected_uid = host_root_uid + options.fetch('uid', 0)
                    expected_gid = host_root_gid + options.fetch('gid', 0)

                    it "has uid=#{expected_uid}" do
                      expect(@tmpfs_opts['uid']).to eq(expected_uid)
                    end

                    it "has gid=#{expected_gid}" do
                      expect(@tmpfs_opts['gid']).to eq(expected_gid)
                    end

                    if options['size']
                      it "has size=#{options['size']}" do
                        expect(@tmpfs_opts['size']).to eq(options['size'])
                      end
                    elsif memory_limit
                      # From the host, size= is visible, while from the container it is not
                      it "has size option set" do
                        expect(@tmpfs_opts['size']).to eq(memory_limit / 2)
                      end
                    else
                      it 'has no size option' do
                        expect(@tmpfs_opts.has_key?('size')).to be(false)
                      end
                    end
                  end
                end
              end
            end
          end
        '';
      };
    };
in
(mkTmpfsScript 1) // (mkTmpfsScript 2)
