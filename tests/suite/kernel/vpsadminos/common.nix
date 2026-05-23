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

  containerSysinfo = pkgs.runCommand "sysinfo-to-json.py" { } ''
    echo "#!/usr/bin/env python3" > $out
    cat ${pkgs.sysinfo-to-json}/bin/sysinfo-to-json >> $out
  '';

  mkMachine =
    {
      cgroupsVersion,
      extraConfig ? ({ ... }: { }),
    }:
    import ../../../machines/vpsadminos/with-tank.nix {
      inherit pkgs;
      config =
        { pkgs, lib, ... }:
        {
          imports = [ extraConfig ];

          boot.qemu = {
            cpus = vmCpuCount;
            cpu.sockets = 2;
            cpu.cores = 4;
          };

          boot.enableUnifiedCgroupHierarchy = cgroupsVersion == 2;

          environment.systemPackages = with pkgs; [
            python3
            sysinfo-to-json
          ];
        };
    };

  rubyHelpers = ''
    def self.use_cgroups_machine(version)
      @kernel_machine = version == 1 ? cgv1 : cgv2
    end

    def self.machine
      @kernel_machine || cgv2
    end

    def self.ensure_kernel_machine
      machine.start unless machine.running?
      machine.wait_for_osctl_pool('tank')
      machine.wait_until_online
    end

    def self.delete_test_container(ctid)
      machine.succeeds("osctl ct del -f --prune #{ctid} >/dev/null 2>&1 || true")
    end

    def self.cleanup_containers_with_prefix(prefix)
      _, output = machine.succeeds("osctl ct ls -H -o id 2>/dev/null || true")

      output.lines.map(&:strip).each do |ctid|
        next unless ctid.start_with?("#{prefix}-")

        delete_test_container(ctid)
      end
    end

    def self.push_sysinfo_script
      machine.mkdir_p('/scripts')
      machine.push_file('${containerSysinfo}', '/scripts/sysinfo.py')
    end

    def self.push_cpu_view_scripts
      machine.mkdir_p('/scripts')
      machine.push_file('${getAffinity}', '/scripts/sched_getaffinity.py')
      machine.push_file('${setAffinity}', '/scripts/sched_setaffinity.py')
      machine.push_file(
        '${setAffinityAndGet}',
        '/scripts/sched_setaffinity_and_get.py'
      )
    end

    def self.ct_apk_add(testct, *packages)
      wait_until_block_succeeds(
        name: "install #{packages.join(', ')} in #{testct}",
        timeout: 420
      ) do
        begin
          machine.succeeds(
            "osctl ct exec #{testct} apk add #{packages.join(' ')}",
            timeout: 300
          )
        rescue OsVm::TimeoutError
          false
        end
      end
    end
  '';

  useMachine = cgroupsVersion: ''
    ${rubyHelpers}
    use_cgroups_machine(${toString cgroupsVersion})
  '';
in
{
  inherit
    vmCpuCount
    mkMachine
    getAffinity
    setAffinity
    setAffinityAndGet
    containerSysinfo
    rubyHelpers
    useMachine
    ;
}
