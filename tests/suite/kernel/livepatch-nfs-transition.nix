# Acceptance case for the NFS cancellation livepatch
#
# Question this test answers: does the cancellation module's transition complete
# and reverse when an *idle* NFSv4 client's state manager is already parked in
# nfs4_run_state_manager()'s wait?
#
# When the payload patched that function, the parked kthread kept a task inside a
# patched frame, so klp could neither finish nor reverse the transition (the
# node1.stg canary stall). With the loop unpatched and the cancellation path
# sending SIGKILL instead, both legs must complete.
#
# Run (test-runner, from the OS tree):
#   VPSADMINOS_LIVEPATCH_SINGLE_SERIES_MODULE=<store>/lib/modules/6.12.95/extra/livepatch_7.ko \
#     ./test-runner.sh test -f --stop-on-failure -j 1 -t ci \
#     --state-dir <state>/run kernel/livepatch-nfs-transition
#
# The test is registered only when VPSADMINOS_LIVEPATCH_SINGLE_SERIES_MODULE is
# set, so ordinary test discovery and CI do not require a task-local module.
import ../../make-test.nix (
  { pkgs }:
  let
    moduleEnv = builtins.getEnv "VPSADMINOS_LIVEPATCH_SINGLE_SERIES_MODULE";
    qualifying = moduleEnv == "";
    selectedModule =
      if qualifying then builtins.getEnv "VPSADMINOS_LIVEPATCH_CORRECTED_MODULE" else moduleEnv;
    expectedSha256 = (import ../../fixtures/livepatch { inherit pkgs; }).correctedSha256;
    # The livepatch name is parameterised so a module with a different name
    # (for example a differently named single-series build) can run
    # through the same case; the default is the single-series name.
    moduleNameEnv = builtins.getEnv "VPSADMINOS_LIVEPATCH_MODULE_NAME";
    moduleName = if moduleNameEnv == "" then "livepatch_7" else moduleNameEnv;
  in
  assert selectedModule != "";
  assert
    !qualifying
    || (
      moduleName == "livepatch_7"
      && builtins.hashFile "sha256" (builtins.storePath selectedModule) == expectedSha256
    );
  {
    name = "kernel-livepatch-nfs-transition";
    description =
      "NFS cancellation livepatch: forward and reverse transition complete "
      + "while an idle NFSv4 state manager is parked";
    tags =
      if qualifying then
        [
          "livepatch-amd"
          "livepatch-intel"
        ]
      else
        [ "ci" ];

    machine = import ../../machines/vpsadminos/with-empty.nix {
      inherit pkgs;
      config =
        { lib, ... }:
        {
          imports = [ ../../configs/vpsadminos/livepatch-6.12.95-boot-base.nix ];
          boot.kernelVersion = lib.mkForce "6.12.95";

          # The test loads the module itself, after the state manager parks.
          services.live-patches.enable = false;
          networking.firewall.allowedTCPPorts = [ 2049 ];

          services.nfs.server = {
            enable = true;
            exports = ''
              /tmp 127.0.0.1(rw,fsid=0,no_subtree_check,no_root_squash,insecure) 192.0.2.0/24(rw,fsid=0,no_subtree_check,no_root_squash,insecure)
            '';
            nfsd.allowedVersions = [
              "4"
              "4.1"
              "4.2"
            ];
          };

          environment.systemPackages = [
            pkgs.binutils
            pkgs.iproute2
            pkgs.kmod
            pkgs.procps
            pkgs.util-linux
          ];

          environment.etc."livepatch-nfs-transition/module.ko".source = builtins.storePath selectedModule;
        };
    };

    testScript = ''
      NFS_STATE = "/run/livepatch-nfs"
      MODULE_NAME = ${builtins.toJSON moduleName}
      MODULE_SHA256 = ${if qualifying then builtins.toJSON expectedSha256 else "nil"}
      MODULE_FILE = "/etc/livepatch-nfs-transition/module.ko"
      PATCH_DIR = "/sys/kernel/livepatch/#{MODULE_NAME}"

      # The parked-frame precondition is proved from the kernel's own stacks: a
      # task stopped inside nfs4_run_state_manager() is exactly what blocks a klp
      # transition. Name matching is not reliable here -- kthread names are
      # truncated to 15 characters, and this guest's `ps -e -o pid=,comm=` returns
      # empty output at status 0 (recorded in the control run's machine-shell.log).
      def parked_state_manager_tasks
        machine.succeeds(
          "for p in /proc/[0-9]*; do " \
            "s=$(cat \"$p/stack\" 2>/dev/null) || continue; " \
            "case \"$s\" in *nfs4_run_state_manager*) echo \"$p\";; esac; " \
            "done | head -5"
        )[1].split
      end

      def create_parked_namespaced_client(name, subnet)
        dir = "#{NFS_STATE}/#{name}"
        server = "192.0.2.#{subnet + 1}"
        client = "192.0.2.#{subnet + 2}"
        host_if = "lp-#{name}"
        before = parked_state_manager_tasks
        machine.succeeds("mkdir -p #{dir}/mnt")
        machine.succeeds(
          "unshare --user --map-root-user --net sh -ec 'echo $$ > #{dir}/pid; " \
            "exec sleep 3600' > #{dir}/holder.log 2>&1 < /dev/null &"
        )
        machine.wait_until_succeeds("test -s #{dir}/pid", timeout: 30)
        pid = Integer(machine.succeeds("cat #{dir}/pid")[1].strip)
        machine.succeeds("test \"$(readlink /proc/#{pid}/ns/user)\" != \"$(readlink /proc/1/ns/user)\"")
        machine.succeeds("ip link add #{host_if} type veth peer name lp-peer")
        machine.succeeds("ip link set lp-peer netns #{pid}")
        machine.succeeds("ip addr add #{server}/30 dev #{host_if} && ip link set #{host_if} up")
        machine.succeeds(
          "nsenter -t #{pid} --net sh -ec 'ip link set lo up; " \
            "ip addr add #{client}/30 dev lp-peer; ip link set lp-peer up'"
        )
        # Enter only the network namespace: mounting/control stays privileged
        # in the initial user namespace, while this net belongs to a child.
        machine.succeeds(
          "nsenter -t #{pid} --net mount -t nfs -o vers=4.2,proto=tcp,nosharecache " \
            "#{server}:/ #{dir}/mnt",
          timeout: 180,
        )
        swap = "#{dir}/mnt/swap-#{name}"
        machine.succeeds("dd if=/dev/zero of=#{swap} bs=1M count=32 conv=fsync", timeout: 180)
        machine.succeeds("chmod 600 #{swap} && mkswap #{swap} && swapon #{swap}", timeout: 180)
        managers = parked_state_manager_tasks - before
        expect(managers.length).to eq(1)
        task = managers.fetch(0)
        machine.wait_until_succeeds("grep -q nfs4_run_state_manager #{task}/wchan", timeout: 30)
        expect(machine.succeeds("cat #{task}/stack")[1]).to match(/nfs4_run_state_manager.*\[nfsv4\]/)
        start_time = machine.succeeds("awk '{print $22}' #{task}/stat")[1].strip
        { name: name, dir: dir, pid: pid, host_if: host_if, swap: swap, task: task, start_time: start_time }
      end

      def cancel_client_namespace(client)
        # Swap is only a fixture for parking the manager, not an I/O workload.
        # Terminal shutdown prevents swapoff from reopening its NFS file. Keep
        # cancelled mounts and unused swaps until normal guest teardown, rather
        # than requiring a successful new OPEN through a shut-down client.
        swap_usage = "awk '$1 == \"#{client[:swap]}\" { print $4 }' /proc/swaps"
        expect(machine.succeeds(swap_usage)[1].strip).to eq('0')
        control = "nsenter -t #{client[:pid]} --net unshare --mount sh -ec"
        machine.succeeds(
          "#{control} 'mount --make-rslave /; mount -t sysfs sysfs /sys; " \
            "test \"$(cat /sys/fs/nfs/net/nfs_client/shutdown)\" = 0; " \
            "echo 1 > /sys/fs/nfs/net/nfs_client/shutdown; " \
            "test \"$(cat /sys/fs/nfs/net/nfs_client/shutdown)\" = 1'",
          timeout: 60,
        )
        machine.wait_until_succeeds("test ! -d #{client[:task]}", timeout: 60)
        expect(machine.succeeds(swap_usage)[1].strip).to eq('0')
      end

      def remove_namespaced_client(client)
        machine.succeeds("swapoff #{client[:swap]}", timeout: 180)
        machine.succeeds("umount #{client[:dir]}/mnt", timeout: 180)
        machine.succeeds("kill #{client[:pid]}")
        machine.wait_until_succeeds("test ! -d /proc/#{client[:pid]}", timeout: 30)
        machine.wait_until_succeeds("! ip link show #{client[:host_if]}", timeout: 30)
      end

      before(:suite) do
        machine.start
        machine.wait_until_online
        machine.succeeds("test \"$(uname -r)\" = 6.12.95")
        unless MODULE_SHA256.nil?
          machine.succeeds("test \"$(sha256sum #{MODULE_FILE} | cut -d' ' -f1)\" = #{MODULE_SHA256}")
        end
      end

      describe 'NFS cancellation livepatch with a parked state manager' do
        before(:example) do
          @nfs_dmesg_start = machine.succeeds("dmesg | wc -l")[1].to_i + 1
          machine.fails("test -d /sys/module/#{MODULE_NAME}")
        end

        after(:example) do
          if machine.running?
            machine.execute("test ! -d #{NFS_STATE}/load || touch #{NFS_STATE}/load/stop")
            diagnostics = machine.succeeds("dmesg | tail -n +#{@nfs_dmesg_start}")[1]
            expect(diagnostics).not_to match(/BUG:|WARNING:|Oops:|kernel panic|soft lockup|hard LOCKUP|hung task|blocked for more than|rcu.*stall/i)
          end
        end

        it 'activates and reverses while the NFSv4 state manager is idle' do
          # NFSv4.2 over loopback, the same shape the main livepatch suite uses.
          machine.succeeds('modprobe nfsv4')
          machine.succeeds("mkdir -p #{NFS_STATE}/mnt")
          machine.succeeds(
            "mount -t nfs -o vers=4.2,proto=tcp,nosharecache " \
              "127.0.0.1:/ #{NFS_STATE}/mnt",
            timeout: 180,
          )
          # A fresh NFSv4 server may still be in its recovery grace period.
          machine.succeeds("touch #{NFS_STATE}/mnt/klp-nfs-lock", timeout: 180)

          # Park a *resident* state manager: an ordinary idle NFSv4 client's
          # manager exits after its first pass, because the loop's park branch is
          # gated on NFS4CLNT_MANAGER_AVAILABLE, which only the swap path sets
          # (nfs_swap_activate -> rpc_clnt_swap_activate -> clnt->cl_swapper). The
          # node1.stg canary's stall came from exactly such a client.
          machine.succeeds("dd if=/dev/zero of=#{NFS_STATE}/mnt/swapfile bs=1M count=32", timeout: 300)
          machine.succeeds("chmod 600 #{NFS_STATE}/mnt/swapfile")
          machine.succeeds("mkswap #{NFS_STATE}/mnt/swapfile", timeout: 300)
          machine.succeeds("swapon #{NFS_STATE}/mnt/swapfile", timeout: 300)
          machine.succeeds("grep -q 'swapfile' /proc/swaps")

          # Precondition evidence: the manager is resident and parked.
          parked = parked_state_manager_tasks
          puts "tasks parked in nfs4_run_state_manager: #{parked.inspect}"
          if parked.empty?
            # Self-diagnosing fallback: show what the guest does report.
            puts "ps -e -o pid=,comm= output: " \
                 "#{machine.succeeds('ps -e -o pid=,comm= | head -20 || true')[1].inspect}"
          end
          expect(parked).not_to be_empty
          parked.each do |task_path|
            wchan = machine.succeeds("cat #{task_path}/wchan 2>/dev/null || true")[1].strip
            puts "parked task path=#{task_path} wchan=#{wchan}"
          end

          # The former patched wait loop stalled here. Require completed
          # activation while the original manager is still parked.
          machine.succeeds(
            'insmod /etc/livepatch-nfs-transition/module.ko',
            timeout: 300,
          )
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 300
          loop do
            enabled = machine.succeeds("cat #{PATCH_DIR}/enabled 2>&1 || true")[1].strip
            transition = machine.succeeds("cat #{PATCH_DIR}/transition 2>&1 || true")[1].strip
            puts "post-insmod: enabled=#{enabled.inspect} transition=#{transition.inspect} livepatch_dir=#{machine.succeeds('ls /sys/kernel/livepatch/ 2>&1 || true')[1].strip.inspect}"
            break if enabled == '1' && transition == '0'
            raise "forward leg did not settle: enabled=#{enabled.inspect} transition=#{transition.inspect}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
            sleep 5
          end

          # Reverse leg: a stalled transition cannot even be reversed.
          machine.succeeds("sh -c 'echo 0 > #{PATCH_DIR}/enabled'", timeout: 300)
          # Instrumented reverse leg: print the observed state every 10 s and fail
          # with the values rather than an opaque timeout.
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 300
          iteration = 0
          loop do
            iteration += 1
            enabled = machine.succeeds("cat #{PATCH_DIR}/enabled 2>&1 || true")[1].strip
            transition = machine.succeeds("cat #{PATCH_DIR}/transition 2>&1 || true")[1].strip
            dir_state = machine.succeeds("test -e #{PATCH_DIR}/enabled && echo present || echo gone")[1].strip
            puts "post-disable: enabled=#{enabled.inspect} transition=#{transition.inspect} patch_dir=#{dir_state} livepatch_dir=#{machine.succeeds('ls /sys/kernel/livepatch/ 2>&1 || true')[1].strip.inspect}"
            if iteration == 3
              # Name what holds the transition open: derive the module's patched-function
              # list from its own .text.<name> sections, then report tasks whose stacks
              # sit in one of them.
              machine.succeeds("readelf -SW #{MODULE_FILE} | grep -oE 'text[.][A-Za-z0-9_.]+' | sed 's/.*[.]//' | sort -u > /run/lp-targets", timeout: 120)
              # NB: never pipe the scan into head - SIGPIPE (141) fails the step.
              machine.succeeds(
                "for p in /proc/[0-9]*; do cat \"$p/stack\" 2>/dev/null > /tmp/s || continue; " \
                  "m=$(grep -m1 -F -f /run/lp-targets /tmp/s); " \
                  "[ -n \"$m\" ] && echo \"$p $m\"; done > /run/lp-stall 2>/dev/null || true",
                timeout: 300,
              )
              probe = machine.succeeds("head -5 /run/lp-stall 2>/dev/null || true")[1]
              puts "stall probe: targets=#{machine.succeeds('wc -l < /run/lp-targets')[1].strip} tasks_in_patched_functions=#{probe.strip.inspect}"
            end
            # A completed reverse leg is the unpatch transition *finishing*, and this
            # module leaves the patch set when it does: a klp module cannot be removed
            # while its patch is enabled or mid-transition, and the upstream suite's
            # own wait_for_patch uses directory-gone for the reversed side. So two
            # shapes are accepted: `transition` back to 0 with the module still
            # loaded, or the patch directory gone (module removed, unpatch done).
            # `enabled` is not usable for this: it reaches 0 as soon as the disable is
            # written, while the transition is still in flight.
            if transition == '0'
              break
            elsif dir_state == 'gone'
              puts "reverse leg: patch directory gone - module removed, unpatch completed"
              puts "reverse leg dmesg: #{machine.succeeds('dmesg 2>/dev/null | grep -iE "livepatch|unpatch" | tail -4 || true')[1].strip.inspect}"
              break
            end
            raise "reverse leg did not settle: enabled=#{enabled.inspect} transition=#{transition.inspect} dir=#{dir_state}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
            sleep 10
          end
          # Idempotent: in the `transition == 0` shape the module is still loaded and
          # this rmmod is what takes it out; in the gone shape it is already out.
          if machine.execute("test -d /sys/module/#{MODULE_NAME}")[0] == 0
            machine.succeeds("rmmod #{MODULE_NAME}", timeout: 300)
          end
          machine.fails("test -d /sys/module/#{MODULE_NAME}")
          lpt_final_dir = machine.succeeds("test -e #{PATCH_DIR}/enabled && echo present || echo gone")[1].strip
          raise "module still present after the reverse leg: #{PATCH_DIR}" unless lpt_final_dir == 'gone'

          # The cancelled client must still be tearable down afterwards.
          machine.succeeds("swapoff #{NFS_STATE}/mnt/swapfile", timeout: 300)
          machine.succeeds("umount #{NFS_STATE}/mnt", timeout: 300)
        end

        it 'activates with four NFSv4 mounts and a parked manager under load' do
          # Separate superblocks do not imply distinct nfs_client objects.
          machine.succeeds('modprobe nfsv4')
          (1..4).each do |i|
            dir = "#{NFS_STATE}/mnt#{i}"
            machine.succeeds("mkdir -p #{dir}")
            machine.succeeds(
              "mount -t nfs -o vers=4.2,proto=tcp,nosharecache 127.0.0.1:/ #{dir}",
              timeout: 180,
            )
            machine.succeeds("touch #{dir}/klp-nfs-lock-#{i}", timeout: 180)
          end

          # One mount is a swap mount, so its client manager stays
          # resident and parked while the rest are ordinary mounts.
          machine.succeeds("dd if=/dev/zero of=#{NFS_STATE}/mnt1/swapfile bs=1M count=32", timeout: 300)
          machine.succeeds("chmod 600 #{NFS_STATE}/mnt1/swapfile")
          machine.succeeds("mkswap #{NFS_STATE}/mnt1/swapfile", timeout: 300)
          machine.succeeds("swapon #{NFS_STATE}/mnt1/swapfile", timeout: 300)

          load = "#{NFS_STATE}/load"
          machine.succeeds("mkdir #{load}")
          machine.succeeds(
            "( sh -ec 'for i in $(seq 1 8); do " \
            "(while ! test -e #{load}/stop; do :; done; touch #{load}/done.$i) & done; wait'; " \
            "echo $? > #{load}/exit ) > #{load}/log 2>&1 &"
          )
          expect(parked_state_manager_tasks).not_to be_empty

          machine.succeeds('insmod /etc/livepatch-nfs-transition/module.ko', timeout: 300)
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 300
          loop do
            enabled = machine.succeeds("cat #{PATCH_DIR}/enabled 2>&1 || true")[1].strip
            transition = machine.succeeds("cat #{PATCH_DIR}/transition 2>&1 || true")[1].strip
            puts "post-insmod: enabled=#{enabled.inspect} transition=#{transition.inspect} livepatch_dir=#{machine.succeeds('ls /sys/kernel/livepatch/ 2>&1 || true')[1].strip.inspect}"
            break if enabled == '1' && transition == '0'
            raise "forward leg did not settle: enabled=#{enabled.inspect} transition=#{transition.inspect}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
            sleep 5
          end
          machine.succeeds("sh -c 'echo 0 > #{PATCH_DIR}/enabled'", timeout: 300)
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 300
          iteration = 0
          loop do
            iteration += 1
            enabled = machine.succeeds("cat #{PATCH_DIR}/enabled 2>&1 || true")[1].strip
            transition = machine.succeeds("cat #{PATCH_DIR}/transition 2>&1 || true")[1].strip
            dir_state = machine.succeeds("test -e #{PATCH_DIR}/enabled && echo present || echo gone")[1].strip
            puts "post-disable: enabled=#{enabled.inspect} transition=#{transition.inspect} patch_dir=#{dir_state} livepatch_dir=#{machine.succeeds('ls /sys/kernel/livepatch/ 2>&1 || true')[1].strip.inspect}"
            if iteration == 3
              # Name what holds the transition open: derive the module's patched-function
              # list from its own .text.<name> sections, then report tasks whose stacks
              # sit in one of them.
              machine.succeeds("readelf -SW #{MODULE_FILE} | grep -oE 'text[.][A-Za-z0-9_.]+' | sed 's/.*[.]//' | sort -u > /run/lp-targets", timeout: 120)
              # NB: never pipe the scan into head - SIGPIPE (141) fails the step.
              machine.succeeds(
                "for p in /proc/[0-9]*; do cat \"$p/stack\" 2>/dev/null > /tmp/s || continue; " \
                  "m=$(grep -m1 -F -f /run/lp-targets /tmp/s); " \
                  "[ -n \"$m\" ] && echo \"$p $m\"; done > /run/lp-stall 2>/dev/null || true",
                timeout: 300,
              )
              probe = machine.succeeds("head -5 /run/lp-stall 2>/dev/null || true")[1]
              puts "stall probe: targets=#{machine.succeeds('wc -l < /run/lp-targets')[1].strip} tasks_in_patched_functions=#{probe.strip.inspect}"
            end
            # A completed reverse leg is the unpatch transition *finishing*, and this
            # module leaves the patch set when it does: a klp module cannot be removed
            # while its patch is enabled or mid-transition, and the upstream suite's
            # own wait_for_patch uses directory-gone for the reversed side. So two
            # shapes are accepted: `transition` back to 0 with the module still
            # loaded, or the patch directory gone (module removed, unpatch done).
            # `enabled` is not usable for this: it reaches 0 as soon as the disable is
            # written, while the transition is still in flight.
            if transition == '0'
              break
            elsif dir_state == 'gone'
              puts "reverse leg: patch directory gone - module removed, unpatch completed"
              puts "reverse leg dmesg: #{machine.succeeds('dmesg 2>/dev/null | grep -iE "livepatch|unpatch" | tail -4 || true')[1].strip.inspect}"
              break
            end
            raise "reverse leg did not settle: enabled=#{enabled.inspect} transition=#{transition.inspect} dir=#{dir_state}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
            sleep 10
          end
          # Idempotent: in the `transition == 0` shape the module is still loaded and
          # this rmmod is what takes it out; in the gone shape it is already out.
          if machine.execute("test -d /sys/module/#{MODULE_NAME}")[0] == 0
            machine.succeeds("rmmod #{MODULE_NAME}", timeout: 300)
          end
          machine.fails("test -d /sys/module/#{MODULE_NAME}")
          lpt_final_dir = machine.succeeds("test -e #{PATCH_DIR}/enabled && echo present || echo gone")[1].strip
          raise "module still present after the reverse leg: #{PATCH_DIR}" unless lpt_final_dir == 'gone'

          machine.succeeds("swapoff #{NFS_STATE}/mnt1/swapfile", timeout: 300)
          machine.succeeds("touch #{load}/stop")
          machine.wait_until_succeeds("test -e #{load}/exit", timeout: 60)
          machine.succeeds("test \"$(cat #{load}/exit)\" = 0")
          (1..8).each { |i| machine.succeeds("test -e #{load}/done.#{i}") }
          (1..4).each do |i|
            machine.succeeds("umount #{NFS_STATE}/mnt#{i}", timeout: 300)
          end
        end

        it 'cancels legacy and new managers only in the selected namespace' do
          machine.succeeds('modprobe nfsv4 && modprobe veth')
          legacy = create_parked_namespaced_client('old', 0)
          neighbor = create_parked_namespaced_client('other', 4)
          machine.succeeds("insmod #{MODULE_FILE}", timeout: 300)
          machine.wait_until_succeeds(
            "test \"$(cat #{PATCH_DIR}/enabled)\" = 1 && test \"$(cat #{PATCH_DIR}/transition)\" = 0",
            timeout: 300,
          )
          # Activation must not terminate/recreate either pre-existing task.
          [legacy, neighbor].each do |client|
            expect(machine.succeeds("awk '{print $22}' #{client[:task]}/stat")[1].strip).to eq(client[:start_time])
            expect(machine.succeeds("cat #{client[:task]}/stack")[1]).to match(/nfs4_run_state_manager.*\[nfsv4\]/)
          end
          cancel_client_namespace(legacy)

          # New managers also keep the original entry point. Their referenced
          # task shadow and the legacy fallback must both deliver cancellation.
          fresh = create_parked_namespaced_client('new', 8)
          cancel_client_namespace(fresh)
          expect(machine.succeeds("awk '{print $22}' #{neighbor[:task]}/stat")[1].strip).to eq(neighbor[:start_time])
          witness = "#{neighbor[:dir]}/mnt/neighbor-witness"
          machine.succeeds("printf neighbor-alive | dd of=#{witness} conv=fsync", timeout: 60)
          expect(machine.succeeds("cat #{witness}")[1]).to eq('neighbor-alive')

          machine.succeeds("echo 0 > #{PATCH_DIR}/enabled", timeout: 300)
          machine.wait_until_succeeds("test ! -d #{PATCH_DIR}", timeout: 300)
          machine.succeeds("rmmod #{MODULE_NAME}", timeout: 300)
          machine.fails("test -d /sys/module/#{MODULE_NAME}")
          expect(machine.succeeds("awk '{print $22}' #{neighbor[:task]}/stat")[1].strip).to eq(neighbor[:start_time])
          machine.succeeds("printf neighbor-unpatched | dd of=#{witness} conv=fsync", timeout: 60)
          expect(machine.succeeds("cat #{witness}")[1]).to eq('neighbor-unpatched')
          remove_namespaced_client(neighbor)
        end
      end
    '';
  }
)
