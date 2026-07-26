{ common }:
let
  mkCpuViewScript =
    cgroupsVersion:
    let
      version = toString cgroupsVersion;
      prefix = "kcpuv${version}";
    in
    {
      "cpu-view-cgroups-v${version}" = {
        description = ''
          Test CPU view virtualization with cgroups v${version}
        '';

        script = common.useMachine cgroupsVersion + ''
          @cpu_view_testct = nil

          def self.testct
            @cpu_view_testct ||= get_container_id('${prefix}')
          end

          configure_examples do |config|
            config.default_order = :defined
          end

          before(:suite) do
            ensure_kernel_machine
            cleanup_containers_with_prefix('${prefix}')
            push_cpu_view_scripts

            machine.all_succeed(
              "osctl ct new --distribution alpine #{testct}",
              "osctl ct unset start-menu #{testct}",
              "osctl ct netif new bridge --link lxcbr0 #{testct} eth0",
              "osctl ct start #{testct}"
            )

            machine.wait_until_container_online(testct, timeout: 60)
            ct_apk_add(testct, 'python3')
          end

          after(:suite) do
            cleanup_containers_with_prefix('${prefix}')
          end

          # Containers without limits and without cpuset have the same view as the host
          def self.compare_exec(command)
            _, host_output = machine.succeeds(command)
            _, ct_output = machine.succeeds("osctl ct exec #{testct} #{command}")

            expect(host_output).to eq(ct_output)
          end

          def self.compare_runscript(script)
            _, host_output = machine.succeeds(script)
            _, ct_output = machine.succeeds("osctl ct runscript #{testct} #{script}")

            expect(host_output).to eq(ct_output)
          end

          def self.container_cpuset
            ${
              if cgroupsVersion == 2 then
                ''
                  _, cpus = machine.succeeds(
                    "osctl ct exec #{testct} cat /sys/fs/cgroup/cpuset.cpus"
                  )
                ''
              else
                ''
                  _, cpus = machine.succeeds(
                    "osctl ct exec #{testct} " \
                      "cat /sys/fs/cgroup/cpuset/cpuset.cpus"
                  )
                ''
            }

            cpus.strip
          end

          def self.nolimit_checks
            it 'has unmodified /proc/stat' do
              compare_exec("cat /proc/stat | grep -P '^cpu\[\\d+\]* ' | awk '{ print $1; }'")
            end

            it 'has unmodified /proc/cpuinfo' do
              compare_exec('grep processor /proc/cpuinfo')
            end

            it 'has unmodified /sys/devices/system/cpu/online' do
              compare_exec('cat /sys/devices/system/cpu/online')
            end

            it 'has unmodified /sys/devices/system/cpuN' do
              compare_exec("find /sys/devices/system/cpu -maxdepth 1 -type d | grep -P '/cpu\\d+' | sort")
            end
          end

          describe 'Unlimited CPU view without cpuset' do
            before(:context) do
              machine.succeeds("osctl ct unset cpu-limit #{testct}")
              machine.succeeds("osctl ct cgparams unset #{testct} cpuset.cpus")
            end

            nolimit_checks

            it 'has identical nproc' do
              compare_exec('nproc')
            end

            it 'has identical getconf' do
              compare_exec('getconf _NPROCESSORS_ONLN')
            end

            it 'can get/set affinity' do
              compare_runscript('/scripts/sched_getaffinity.py')

              _, nolimit_affinity = machine.succeeds("osctl ct runscript #{testct} /scripts/sched_getaffinity.py")
              machine.succeeds("osctl ct runscript #{testct} /scripts/sched_setaffinity.py #{nolimit_affinity.strip}")
            end
          end

          # Containers with cpuset see all CPUs, except that nproc (sched_getaffinity())
          # takes the cpuset into account
          cpu_mask = '2,3,4'
          cpu_count = cpu_mask.split(',').count

          describe 'Unlimited CPU view with cpuset' do
            before(:context) do
              machine.succeeds("osctl ct unset cpu-limit #{testct}")
              machine.succeeds("osctl ct cgparams set #{testct} cpuset.cpus #{cpu_mask}")
            end

            it 'has configured cpuset' do
              expect(container_cpuset).to eq('2-4')
            end

            nolimit_checks

            it 'affects nproc' do
              _, cpuset_nproc = machine.succeeds("osctl ct exec #{testct} nproc")

              expect(cpuset_nproc.strip.to_i).to eq(cpu_count)
            end

            it 'affects getconf' do
              _, cpuset_getconf = machine.succeeds("osctl ct exec #{testct} getconf _NPROCESSORS_ONLN")

              expect(cpuset_getconf.strip.to_i).to eq(cpu_count)
            end

            it 'can get/set affinity' do
              _, cpuset_affinity = machine.succeeds("osctl ct runscript #{testct} /scripts/sched_getaffinity.py")

              expect(cpuset_affinity.strip).to eq(cpu_mask)

              machine.succeeds("osctl ct runscript #{testct} /scripts/sched_setaffinity.py #{cpuset_affinity.strip}")
            end
          end

          describe 'Dynamic cpuset hierarchy changes' do
            after(:context) do
              machine.succeeds(
                "osctl ct cgparams set #{testct} cpuset.cpus 2-4"
              )
            end

            it 'expands the active hierarchy' do
              machine.succeeds(
                "osctl ct cgparams set #{testct} cpuset.cpus 1-6"
              )

              expect(container_cpuset).to eq('1-6')
            end

            it 'switches to a disjoint mask' do
              machine.succeeds(
                "osctl ct cgparams set #{testct} cpuset.cpus 7"
              )

              expect(container_cpuset).to eq('7')
            end

            it 'keeps the policy across a managed restart' do
              machine.succeeds("osctl ct restart #{testct}")
              machine.wait_until_container_online(testct, timeout: 60)

              expect(container_cpuset).to eq('7')
            end

            it 'resets to the scheduler or parent mask' do
              machine.succeeds(
                "osctl ct cgparams unset #{testct} cpuset.cpus"
              )

              expect(container_cpuset).to eq('0-7')
            end
          end

          describe 'Persisted CPU bandwidth lifecycle' do
            before(:context) do
              machine.all_succeed(
                "osctl ct cgparams unset #{testct} cpuset.cpus",
                "osctl ct set cpu-limit #{testct} 250"
              )
            end

            it 'starts with the persisted limit' do
              machine.succeeds("osctl ct stop #{testct}")
              machine.succeeds("osctl ct start #{testct}")
              machine.wait_until_container_online(testct, timeout: 60)

              _, nproc = machine.succeeds("osctl ct exec #{testct} nproc")
              expect(nproc.strip.to_i).to eq(3)
            end

            it 'restarts with the persisted limit' do
              machine.succeeds("osctl ct restart #{testct}")
              machine.wait_until_container_online(testct, timeout: 60)

              _, nproc = machine.succeeds("osctl ct exec #{testct} nproc")
              expect(nproc.strip.to_i).to eq(3)
            end
          end

          describe 'Configured group hierarchy reconstruction' do
            ctid = "#{get_container_id('${prefix}-group')}"
            parent_group = "/${prefix}-launch"
            child_group = "#{parent_group}/child"
            ${
              if cgroupsVersion == 2 then
                ''
                  group_cgroup_root =
                    "/sys/fs/cgroup/osctl/pool.tank/" \
                      "group.${prefix}-launch"
                ''
              else
                ''
                  group_cgroup_root =
                    "/sys/fs/cgroup/cpuset/osctl/pool.tank/" \
                      "group.${prefix}-launch"
                ''
            }

            before(:context) do
              delete_test_container(ctid)
              machine.succeeds("osctl group del #{child_group} || true")
              machine.succeeds("osctl group del #{parent_group} || true")
              machine.all_succeed(
                "osctl ct new --distribution alpine #{ctid}",
                "osctl ct unset start-menu #{ctid}",
                "osctl group new --parents #{child_group}",
                "osctl group cgparams set #{parent_group} " \
                  "cpuset.cpus 0-5",
                "osctl group cgparams set #{child_group} " \
                  "cpuset.cpus 2-4",
                "rmdir #{group_cgroup_root}/group.child",
                "rmdir #{group_cgroup_root}",
                "sv -w 60 restart osctld"
              )
              machine.wait_for_osctl_pool('tank')
              machine.all_succeed(
                "osctl group cgparams apply #{child_group}",
                "osctl ct chgrp #{ctid} #{child_group}",
                "osctl ct cgparams set #{ctid} cpuset.cpus 3-4"
              )
            end

            after(:context) do
              delete_test_container(ctid)
              machine.succeeds("osctl group del #{child_group}")
              machine.succeeds("osctl group del #{parent_group}")
            end

            it 'rebuilds parent cpusets before stopped execution' do
              _, cpus = machine.succeeds(
                "osctl ct exec -r #{ctid} " \
                  "awk '/Cpus_allowed_list/ { print $2 }' /proc/self/status"
              )

              expect(cpus.strip).to eq('3-4')
            end

            it 'starts below reconstructed group controller policy' do
              machine.succeeds("osctl ct start #{ctid}")

              ${
                if cgroupsVersion == 2 then
                  ''
                    _, cpus = machine.succeeds(
                      "osctl ct exec #{ctid} " \
                        "cat /sys/fs/cgroup/cpuset.cpus"
                    )
                  ''
                else
                  ''
                    _, cpus = machine.succeeds(
                      "osctl ct exec #{ctid} " \
                        "cat /sys/fs/cgroup/cpuset/cpuset.cpus"
                    )
                  ''
              }

              expect(cpus.strip).to eq('3-4')
            end
          end

          describe 'Configured group CPU bandwidth hierarchy' do
            ctid = "#{get_container_id('${prefix}-group-cpu')}"
            parent_group = "/${prefix}-cpu"
            child_group = "#{parent_group}/child"
            stopped_group = "#{parent_group}/stopped"
            ${
              if cgroupsVersion == 2 then
                ''
                  group_cpu_root =
                    "/sys/fs/cgroup/osctl/pool.tank/" \
                      "group.${prefix}-cpu"
                ''
              else
                ''
                  group_cpu_root =
                    "/sys/fs/cgroup/cpu,cpuacct/osctl/pool.tank/" \
                      "group.${prefix}-cpu"
                ''
            }
            child_cpu_cgroup = "#{group_cpu_root}/group.child"
            stopped_cpu_cgroup = "#{group_cpu_root}/group.stopped"
            cgroup_task_file =
              '${if cgroupsVersion == 2 then "cgroup.procs" else "tasks"}'
            read_group_cpu = lambda do |path|
              ${
                if cgroupsVersion == 2 then
                  ''
                    _, value = machine.succeeds("cat #{path}/cpu.max")
                    quota, period = value.strip.split
                    {
                      quota: quota == 'max' ? -1 : quota.to_i,
                      period: period.to_i
                    }
                  ''
                else
                  ''
                    _, quota = machine.succeeds(
                      "cat #{path}/cpu.cfs_quota_us"
                    )
                    _, period = machine.succeeds(
                      "cat #{path}/cpu.cfs_period_us"
                    )
                    {
                      quota: quota.strip.to_i,
                      period: period.strip.to_i
                    }
                  ''
              }
            end

            before(:context) do
              delete_test_container(ctid)
              machine.succeeds("osctl group del #{stopped_group} || true")
              machine.succeeds("osctl group del #{child_group} || true")
              machine.succeeds("osctl group del #{parent_group} || true")
              machine.all_succeed(
                "osctl ct new --distribution alpine #{ctid}",
                "osctl ct unset start-menu #{ctid}",
                "osctl group new --parents #{child_group}",
                "osctl group new #{stopped_group}",
                "osctl group set cpu-limit #{parent_group} 400",
                "osctl group set cpu-limit #{child_group} 300",
                "osctl group set cpu-limit #{stopped_group} 200",
                "osctl ct chgrp #{ctid} #{child_group}"
              )
              _, lxc_path = machine.succeeds(
                "osctl ct show -H -o lxc_path #{ctid}"
              )
              _, system_user = machine.succeeds(
                "osctl user show -H -o username #{ctid}"
              )
              machine.all_succeed(
                "sv -w 120 stop osctld",
                "chpst -u #{system_user.strip} " \
                  "lxc-monitor -P #{lxc_path.strip} --quit || true"
              )
              machine.wait_until_succeeds(
                "test -z \"$(find #{group_cpu_root} " \
                  "-name #{cgroup_task_file} -exec cat {} +)\"",
                timeout: 120
              )
              machine.all_succeed(
                "find #{group_cpu_root} -depth -type d -exec rmdir {} +",
                "sv start osctld"
              )
              machine.wait_for_osctl_pool('tank')
            end

            after(:context) do
              delete_test_container(ctid)
              machine.succeeds("osctl group del #{stopped_group}")
              machine.succeeds("osctl group del #{child_group}")
              machine.succeeds("osctl group del #{parent_group}")
            end

            it 'applies configured policy to the existing group subtree' do
              ${
                if cgroupsVersion == 2 then
                  ''
                    expect(
                      read_group_cpu.call(stopped_cpu_cgroup)
                    ).to eq(
                      quota: -1,
                      period: 100_000
                    )
                  ''
                else
                  ''
                    machine.fails("test -d #{stopped_cpu_cgroup}")
                  ''
              }
              _, nproc = machine.succeeds(
                "osctl ct exec -r #{ctid} nproc"
              )

              expect(nproc.strip.to_i).to eq(3)
              expect(read_group_cpu.call(group_cpu_root)).to eq(
                quota: 400_000,
                period: 100_000
              )
              expect(read_group_cpu.call(child_cpu_cgroup)).to eq(
                quota: 300_000,
                period: 100_000
              )
              ${
                if cgroupsVersion == 2 then
                  ''
                    expect(
                      read_group_cpu.call(stopped_cpu_cgroup)
                    ).to eq(
                      quota: 200_000,
                      period: 100_000
                    )
                  ''
                else
                  ''
                    machine.fails("test -d #{stopped_cpu_cgroup}")
                  ''
              }
            end

            it 'retains the configured hierarchy across start and restart' do
              machine.succeeds("osctl ct start #{ctid}")
              machine.wait_for_osctl_container(ctid)
              _, started_nproc = machine.succeeds(
                "osctl ct exec #{ctid} nproc"
              )
              expect(started_nproc.strip.to_i).to eq(3)

              machine.succeeds("osctl ct restart #{ctid}")
              machine.wait_for_osctl_container(ctid)
              _, restarted_nproc = machine.succeeds(
                "osctl ct exec #{ctid} nproc"
              )
              expect(restarted_nproc.strip.to_i).to eq(3)
            end

            it 'expands ancestors before descendants' do
              machine.all_succeed(
                "osctl group set cpu-limit #{parent_group} 500",
                "osctl group set cpu-limit #{child_group} 400"
              )

              _, nproc = machine.succeeds("osctl ct exec #{ctid} nproc")
              expect(nproc.strip.to_i).to eq(4)
            end

            it 'restricts descendants before ancestors' do
              machine.all_succeed(
                "osctl group set cpu-limit #{child_group} 200",
                "osctl group set cpu-limit #{parent_group} 250"
              )

              _, nproc = machine.succeeds("osctl ct exec #{ctid} nproc")
              expect(nproc.strip.to_i).to eq(2)
            end

            it 'handles a child request wider than its parent' do
              ${
                if cgroupsVersion == 2 then
                  ''
                    machine.succeeds(
                      "osctl group set cpu-limit #{child_group} 400"
                    )
                    expect(read_group_cpu.call(child_cpu_cgroup)).to eq(
                      quota: 400_000,
                      period: 100_000
                    )
                    _, nproc = machine.succeeds(
                      "osctl ct exec #{ctid} nproc"
                    )
                    expect(nproc.strip.to_i).to eq(3)
                  ''
                else
                  ''
                    _, error = machine.fails(
                      "osctl group set cpu-limit #{child_group} 400"
                    )
                    expect(error).to include(
                      'exceeds prospective parent bandwidth'
                    )
                    expect(read_group_cpu.call(child_cpu_cgroup)).to eq(
                      quota: 200_000,
                      period: 100_000
                    )
                    _, nproc = machine.succeeds(
                      "osctl ct exec #{ctid} nproc"
                    )
                    expect(nproc.strip.to_i).to eq(2)
                  ''
              }
            end

            it 'inherits the finite parent after unsetting the child limit' do
              machine.succeeds(
                "osctl group unset cpu-limit #{child_group}"
              )

              expect(read_group_cpu.call(child_cpu_cgroup)).to eq(
                quota: -1,
                period: 100_000
              )
              _, nproc = machine.succeeds("osctl ct exec #{ctid} nproc")
              expect(nproc.strip.to_i).to eq(3)
            end
          end

          def self.check_cpus(limit, cpu_count)
            before(:context) do
              if limit
                machine.succeeds("osctl ct set cpu-limit #{testct} #{limit}")
              else
                machine.succeeds("osctl ct unset cpu-limit #{testct}")
              end
            end

            it 'virtualizes view in /proc/stat' do
              cpu_lines = cpu_count.times.map { |i| "cpu#{i}" }.join("\n")
              _, limit_stat = machine.succeeds("osctl ct exec #{testct} cat /proc/stat | grep -P '^cpu\[\\d+\]* ' | awk '{ print $1; }'")

              expect(limit_stat.strip).to eq("cpu\n#{cpu_lines}")
            end

            it 'virtualizes view in /proc/cpuinfo' do
              _, limit_cpuinfo = machine.succeeds("osctl ct exec #{testct} grep processor /proc/cpuinfo")
              proc_count = limit_cpuinfo.strip.split("\n").count
              expect(proc_count).to eq(cpu_count)
            end

            it 'virtualizes /sys/devices/system/cpu/online' do
              _, limit_online = machine.succeeds("osctl ct exec #{testct} cat /sys/devices/system/cpu/online")

              cpu_mask = cpu_count > 1 ? "0-#{cpu_count - 1}" : '0'

              expect(limit_online.strip).to eq(cpu_mask)
            end

            it 'virtualizes /sys/devices/system/cpu/cpuN' do
              cpu_sys = cpu_count.times.map { |i| "/sys/devices/system/cpu/cpu#{i}" }.join("\n")

              _, limit_cpus = machine.succeeds("osctl ct exec #{testct} find /sys/devices/system/cpu -maxdepth 1 -type d | grep -P '/cpu\\d+' | sort")

              expect(limit_cpus.strip).to eq(cpu_sys)
            end

            it 'virtualizes nproc' do
              _, limit_nproc = machine.succeeds("osctl ct exec #{testct} nproc")

              expect(limit_nproc.to_i).to eq(cpu_count)
            end

            it 'virtualizes getconf' do
              _, limit_getconf = machine.succeeds("osctl ct exec #{testct} getconf _NPROCESSORS_ONLN")

              expect(limit_getconf.to_i).to eq(cpu_count)
            end

            it 'virtualizes sched_getaffinity()/sched_setaffinity()' do
              cpu_list = (0..(cpu_count - 1)).to_a.join(',')

              _, limit_affinity = machine.succeeds("osctl ct runscript #{testct} /scripts/sched_getaffinity.py")

              expect(limit_affinity.strip).to eq(cpu_list)

              machine.succeeds("osctl ct runscript #{testct} /scripts/sched_setaffinity.py #{limit_affinity.strip}")

              _, clipped_wide_affinity = machine.succeeds(
                "osctl ct runscript #{testct} " \
                  "/scripts/sched_setaffinity_and_get.py 0-1023"
              )

              expect(clipped_wide_affinity.strip).to eq(cpu_list)

              if cpu_count < ${toString common.vmCpuCount}
                extra_cpu = cpu_count
                _, clipped_affinity = machine.succeeds(
                  "osctl ct runscript #{testct} " \
                    "/scripts/sched_setaffinity_and_get.py " \
                    "#{cpu_list},#{extra_cpu}"
                )

                expect(clipped_affinity.strip).to eq(cpu_list)

                machine.fails(
                  "osctl ct runscript #{testct} " \
                    "/scripts/sched_setaffinity_and_get.py " \
                    "#{extra_cpu}"
                )
              end
            end
          end

          describe 'CPU view without cpuset' do
            before(:context) do
              machine.succeeds("osctl ct cgparams unset #{testct} cpuset.cpus")
            end

            context 'with 300% limit' do
              check_cpus(300, 3)
            end

            context 'with 400% limit' do
              check_cpus(400, 4)
            end

            context 'with 250% limit' do
              check_cpus(250, 3)
            end

            context 'with 201% limit' do
              check_cpus(201, 3)
            end

            context 'with 200% limit' do
              check_cpus(200, 2)
            end

            context 'with 100% limit' do
              check_cpus(100, 1)
            end

            context 'with 50% limit' do
              check_cpus(50, 1)
            end

            context 'raise to 800%' do
              check_cpus(800, 8)
            end

            # TODO: kernel bug in /proc/cpuinfo here
            # context '1000% limit' do
            #   check_cpus(1000, 8)
            # end

            context 'with 500% limit' do
              check_cpus(500, 5)
            end

            context 'unset limit' do
              check_cpus(nil, 8)
            end
          end

          describe 'CPU view with cpuset' do
            before(:context) do
              machine.succeeds("osctl ct cgparams set #{testct} cpuset.cpus 2-5")
            end

            context 'with 300% limit' do
              check_cpus(300, 3)
            end

            context 'with 400% limit' do
              check_cpus(400, 4)
            end

            context 'with 250% limit' do
              check_cpus(250, 3)
            end

            context 'with 201% limit' do
              check_cpus(201, 3)
            end

            context 'with 200% limit' do
              check_cpus(200, 2)
            end

            context 'with 100% limit' do
              check_cpus(100, 1)
            end

            context 'with 50% limit' do
              check_cpus(50, 1)
            end

            context 'raise to 800%' do
              check_cpus(800, 8)
            end

            # TODO: kernel bug in /proc/cpuinfo here
            # context 'with 1000% limit' do
            #   check_cpus(1000, 8)
            # end
          end
        '';
      };
    };
in
(mkCpuViewScript 1) // (mkCpuViewScript 2)
