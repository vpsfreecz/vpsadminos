{ cgroupsVersion }:
import ../../../make-test.nix ({ pkgs }:
let
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

  mkScript = script: ''
    machine.wait_for_osctl_pool("tank")
    machine.wait_until_online

    machine.mkdir_p('/scripts')
    machine.push_file('${getAffinity}', '/scripts/sched_getaffinity.py')
    machine.push_file('${setAffinity}', '/scripts/sched_setaffinity.py')

    testct = get_container_id

    machine.all_succeed(
      "osctl ct new --distribution alpine #{testct}",
      "osctl ct unset start-menu #{testct}",
      "osctl ct netif new bridge --link lxcbr0 #{testct} eth0",
      "osctl ct start #{testct}"
    )

    machine.wait_until_container_online(testct, timeout: 60)
    machine.succeeds("osctl ct exec #{testct} apk add python3")

    ${script}

    machine.succeeds("osctl ct del -f --prune #{testct}")
  '';
in {
  name = "kernel-cpu-view-cgroups-v${toString cgroupsVersion}";

  description = ''
    Test CPU view virtualization with cgroups v${toString cgroupsVersion}
  '';

  tags = [ "ci" ];

  machine = import ../../../machines/with-tank.nix {
    inherit pkgs;
    config =
      { config, pkgs, ... }:
      {
        boot.qemu = {
          cpus = 8;
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
        compare_exec = proc do |message, command|
          _, host_output = machine.succeeds(command)
          _, ct_output = machine.succeeds("osctl ct exec #{testct} #{command}")

          if host_output != ct_output
            fail "#{message} differs when no limit is set:\n" \
                "host output:\n#{host_output}\n\n" \
                "container output:\n#{ct_output}"
          end
        end

        compare_runscript = proc do |message, script|
          _, host_output = machine.succeeds(script)
          _, ct_output = machine.succeeds("osctl ct runscript #{testct} #{script}")

          if host_output != ct_output
            fail "#{message} differs when no limit is set:\n" \
                "host output:\n#{host_output}\n\n" \
                "container output:\n#{ct_output}"
          end
        end

        nolimit_checks = proc do
          compare_exec.call("/proc/stat", "cat /proc/stat | grep -P '^cpu\[\\d+\]* ' | awk '{ print $1; }'")
          compare_exec.call("/proc/cpuinfo", "grep processor /proc/cpuinfo")
          compare_exec.call("/sys/devices/system/cpu/online", 'cat /sys/devices/system/cpu/online')
          compare_exec.call("/sys/devices/system/cpuN", "find /sys/devices/system/cpu -maxdepth 1 -type d | grep -P '/cpu\\d+' | sort")
        end

        test 'Unlimited CPU view without cpuset' do
          nolimit_checks.call
          compare_exec.call('nproc', 'nproc')
          compare_exec.call('getconf _NPROCESSORS_ONLN', 'getconf _NPROCESSORS_ONLN')

          compare_runscript.call('sched_getaffinity() without cpuset', '/scripts/sched_getaffinity.py')

          _, nolimit_affinity = machine.succeeds("osctl ct runscript #{testct} /scripts/sched_getaffinity.py")
          machine.succeeds("osctl ct runscript #{testct} /scripts/sched_setaffinity.py #{nolimit_affinity.strip}")
        end

        # Containers with cpuset see all CPUs, except that nproc (sched_getaffinity())
        # takes the cpuset into account
        cpu_mask = '2,3,4'
        cpu_count = cpu_mask.split(',').count

        test 'Unlimited CPU view with cpuset' do
          machine.succeeds("osctl ct cgparams set #{testct} cpuset.cpus #{cpu_mask}")

          ${if cgroupsVersion == 2 then ''
          _, cpus = machine.succeeds("osctl ct exec #{testct} cat /sys/fs/cgroup/cpuset.cpus")
          '' else ''
          _, cpus = machine.succeeds("osctl ct exec #{testct} cat /sys/fs/cgroup/cpuset/cpuset.cpus")
          ''}

          if cpus.strip != '2-4'
            fail "cpuset.cpus set to #{cpus.strip.inspect}, expected '2-4'}"
          end

          nolimit_checks.call

          _, cpuset_nproc = machine.succeeds("osctl ct exec #{testct} nproc")

          if cpuset_nproc.strip.to_i != cpu_count
            fail "Container nproc returned #{cpuset_nproc.strip.inspect}, expected '#{cpu_count}'"
          end

          _, cpuset_getconf = machine.succeeds("osctl ct exec #{testct} getconf _NPROCESSORS_ONLN")

          if cpuset_getconf.strip.to_i != cpu_count
            fail "Container getconf returned #{cpuset_getconf.strip.inspect}, expected '#{cpu_count}'"
          end

          _, cpuset_affinity = machine.succeeds("osctl ct runscript #{testct} /scripts/sched_getaffinity.py")

          if cpuset_affinity.strip != cpu_mask
            fail "Container sched_getaffinity() returned #{cpuset_affinity.strip.inspect}, expected #{cpu_mask.inspect}"
          end

          machine.succeeds("osctl ct runscript #{testct} /scripts/sched_setaffinity.py #{cpuset_affinity.strip}")
        end
      '';
    };

    limited = {
      description = ''
        Test CPU view with cgroups v${toString cgroupsVersion} in containers with CPU limit
      '';

      script = mkScript ''
        check_cpus = proc do |cpu_count|
          cpu_lines = cpu_count.times.map { |i| "cpu#{i}" }.join("\n")

          _, limit_stat = machine.succeeds("osctl ct exec #{testct} cat /proc/stat | grep -P '^cpu\[\\d+\]* ' | awk '{ print $1; }'")

          if limit_stat.strip != "cpu\n#{cpu_lines}"
            fail "Unexpected CPUs in /proc/stat: #{limit_stat.strip.inspect}"
          end

          _, limit_cpuinfo = machine.succeeds("osctl ct exec #{testct} grep processor /proc/cpuinfo")
          proc_count = limit_cpuinfo.strip.split("\n").count

          if proc_count != cpu_count
            fail "Expected #{cpu_count} processors in /proc/cpuinfo, got #{proc_count}"
          end

          _, limit_online = machine.succeeds("osctl ct exec #{testct} cat /sys/devices/system/cpu/online")

          cpu_mask = cpu_count > 1 ? "0-#{cpu_count - 1}" : '0'

          if limit_online.strip != cpu_mask
            fail "Expected /sys/devices/system/cpu/online to contain #{cpu_mask}, got #{limit_online.strip.inspect}"
          end

          cpu_sys = cpu_count.times.map { |i| "/sys/devices/system/cpu/cpu#{i}" }.join("\n")

          _, limit_cpus = machine.succeeds("osctl ct exec #{testct} find /sys/devices/system/cpu -maxdepth 1 -type d | grep -P '/cpu\\d+' | sort")

          if limit_cpus.strip != cpu_sys
            fail "Expected #{cpu_sys.inspect} in /sys/devices/system, got #{limit_cpus.strip.inspect}"
          end

          _, limit_nproc = machine.succeeds("osctl ct exec #{testct} nproc")

          if limit_nproc.to_i != cpu_count
            fail "Expected nproc to return #{cpu_count}, got #{limit_nproc.inspect}"
          end

          _, limit_getconf = machine.succeeds("osctl ct exec #{testct} getconf _NPROCESSORS_ONLN")

          if limit_getconf.to_i != cpu_count
            fail "Expected getconf to return #{cpu_count}, got #{limit_getconf.inspect}"
          end

          cpu_list = (0..(cpu_count - 1)).to_a.join(',')

          _, limit_affinity = machine.succeeds("osctl ct runscript #{testct} /scripts/sched_getaffinity.py")

          if limit_affinity.strip != cpu_list
            fail "Expected sched_getaffinity() to return #{cpu_list.inspect}, got #{limit_affinity.strip.inspect}"
          end

          machine.succeeds("osctl ct runscript #{testct} /scripts/sched_setaffinity.py #{limit_affinity.strip}")
        end

        test 'CPU view without cpuset' do
          test '300% limit' do
            machine.succeeds("osctl ct set cpu-limit #{testct} 300")
            check_cpus.call(3)
          end

          test '400% limit' do
            machine.succeeds("osctl ct set cpu-limit #{testct} 400")
            check_cpus.call(4)
          end

          test '250% limit' do
            machine.succeeds("osctl ct set cpu-limit #{testct} 250")
            check_cpus.call(3)
          end

          test '201% limit' do
            machine.succeeds("osctl ct set cpu-limit #{testct} 201")
            check_cpus.call(3)
          end

          test '200% limit' do
            machine.succeeds("osctl ct set cpu-limit #{testct} 200")
            check_cpus.call(2)
          end

          test '100% limit' do
            machine.succeeds("osctl ct set cpu-limit #{testct} 100")
            check_cpus.call(1)
          end

          test '50% limit' do
            machine.succeeds("osctl ct set cpu-limit #{testct} 50")
            check_cpus.call(1)
          end

          test 'raise to 800%' do
            machine.succeeds("osctl ct set cpu-limit #{testct} 800")
            check_cpus.call(8)
          end

          # TODO: kernel bug in /proc/cpuinfo here
          # test '1000% limit' do
          #   machine.succeeds("osctl ct set cpu-limit #{testct} 1000")
          #   check_cpus.call(8)
          # end

          test '500% limit' do
            machine.succeeds("osctl ct set cpu-limit #{testct} 500")
            check_cpus.call(5)
          end

          test 'unset limit' do
            machine.succeeds("osctl ct unset cpu-limit #{testct}")
            check_cpus.call(8)
          end
        end

        test 'CPU view with cpuset' do
          machine.succeeds("osctl ct cgparams set #{testct} cpuset.cpus 2-5")

          test '300% limit' do
            machine.succeeds("osctl ct set cpu-limit #{testct} 300")
            check_cpus.call(3)
          end

          test '400% limit' do
            machine.succeeds("osctl ct set cpu-limit #{testct} 400")
            check_cpus.call(4)
          end

          test '250% limit' do
            machine.succeeds("osctl ct set cpu-limit #{testct} 250")
            check_cpus.call(3)
          end

          test '201% limit' do
            machine.succeeds("osctl ct set cpu-limit #{testct} 201")
            check_cpus.call(3)
          end

          test '200% limit' do
            machine.succeeds("osctl ct set cpu-limit #{testct} 200")
            check_cpus.call(2)
          end

          test '100% limit' do
            machine.succeeds("osctl ct set cpu-limit #{testct} 100")
            check_cpus.call(1)
          end

          test '50% limit' do
            machine.succeeds("osctl ct set cpu-limit #{testct} 50")
            check_cpus.call(1)
          end

          test 'raise to 800%' do
            machine.succeeds("osctl ct set cpu-limit #{testct} 800")
            check_cpus.call(8)
          end

          # TODO: kernel bug in /proc/cpuinfo here
          # test '1000% limit' do
          #   machine.succeeds("osctl ct set cpu-limit #{testct} 1000")
          #   check_cpus.call(8)
          # end
        end
      '';
    };
  };
})
