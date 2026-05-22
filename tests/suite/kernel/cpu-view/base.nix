{ cgroupsVersion }:
import ../../../make-test.nix (
  { pkgs }:
  let
    vmCpuCount = 8;

    getAffinity = pkgs.writeScript "sched_getaffinity.py" ''
      #!/usr/bin/env python3
      import os


      cpus = os.sched_getaffinity(0)
      print(','.join(str(v) for v in sorted(cpus)))
    '';

    setAffinity = pkgs.writeScript "sched_setaffinity.py" ''
      #!/usr/bin/env python3
      import os
      import sys


      if len(sys.argv) != 2:
        print(f'Usage: {sys.argv[0]} <cpu>[,cpu...]')
        sys.exit(1)

      os.sched_setaffinity(0, (int(v) for v in sys.argv[1].split(',')))
    '';

    setAffinityAndGet = pkgs.writeScript "sched_setaffinity_and_get.py" ''
      #!/usr/bin/env python3
      import ctypes
      import ctypes.util
      import os
      import sys


      def parse_cpus(spec):
        cpus = []

        for part in spec.split(','):
          if '-' in part:
            start, end = (int(v) for v in part.split('-', 1))
            cpus.extend(range(start, end + 1))
          else:
            cpus.append(int(part))

        return cpus


      if len(sys.argv) != 2:
        print(f'Usage: {sys.argv[0]} <cpu>[,cpu...|cpu-cpu]')
        sys.exit(1)

      libc = ctypes.CDLL(ctypes.util.find_library('c'), use_errno=True)
      CLONE_NEWCGROUP = 0x02000000

      if libc.unshare(CLONE_NEWCGROUP) != 0:
        err = ctypes.get_errno()
        raise OSError(err, os.strerror(err))

      os.sched_setaffinity(0, parse_cpus(sys.argv[1]))

      cpus = os.sched_getaffinity(0)
      print(','.join(str(v) for v in sorted(cpus)))
    '';

    mkScript = script: ''
      def self.testct
        @testct ||= get_container_id
      end

      before(:suite) do
        machine.wait_for_osctl_pool("tank")
        machine.wait_until_online

        machine.mkdir_p('/scripts')
        machine.push_file('${getAffinity}', '/scripts/sched_getaffinity.py')
        machine.push_file('${setAffinity}', '/scripts/sched_setaffinity.py')
        machine.push_file(
          '${setAffinityAndGet}',
          '/scripts/sched_setaffinity_and_get.py'
        )

        machine.all_succeed(
          "osctl ct new --distribution alpine #{testct}",
          "osctl ct unset start-menu #{testct}",
          "osctl ct netif new bridge --link lxcbr0 #{testct} eth0",
          "osctl ct start #{testct}"
        )

        machine.wait_until_container_online(testct, timeout: 60)
        machine.succeeds("osctl ct exec #{testct} apk add python3")
      end

      ${script}

      after(:suite) do
        machine.succeeds("osctl ct del -f --prune #{testct}")
      end
    '';
  in
  {
    name = "kernel-cpu-view-cgroups-v${toString cgroupsVersion}";

    description = ''
      Test CPU view virtualization with cgroups v${toString cgroupsVersion}
    '';

    tags = [ "ci" ];

    machine = import ../../../machines/vpsadminos/with-tank.nix {
      inherit pkgs;
      config =
        { config, pkgs, ... }:
        {
          boot.qemu = {
            cpus = vmCpuCount;
            cpu.sockets = 2;
            cpu.cores = 4;
          };

          boot.enableUnifiedCgroupHierarchy = cgroupsVersion == 2;

          environment.systemPackages = with pkgs; [ python3 ];
        };
    };

    testScripts = {
      unlimited = {
        description = ''
          Test CPU view with cgroups v${toString cgroupsVersion} in containers when no CPU limit is set
        '';

        script = mkScript ''
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
              machine.succeeds("osctl ct cgparams set #{testct} cpuset.cpus #{cpu_mask}")
            end

            it 'has configured cpuset' do
              ${
                if cgroupsVersion == 2 then
                  ''
                    _, cpus = machine.succeeds("osctl ct exec #{testct} cat /sys/fs/cgroup/cpuset.cpus")
                  ''
                else
                  ''
                    _, cpus = machine.succeeds("osctl ct exec #{testct} cat /sys/fs/cgroup/cpuset/cpuset.cpus")
                  ''
              }

              expect(cpus.strip).to eq('2-4')
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
        '';
      };

      limited = {
        description = ''
          Test CPU view with cgroups v${toString cgroupsVersion} in containers with CPU limit
        '';

        script = mkScript ''
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

              if cpu_count < ${toString vmCpuCount}
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
  }
)
