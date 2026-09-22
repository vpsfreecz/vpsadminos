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
    # The livepatch name is parameterised so a module with a different name
    # (for example a differently named single-series build) can run
    # through the same case; the default is the single-series name.
    moduleNameEnv = builtins.getEnv "VPSADMINOS_LIVEPATCH_MODULE_NAME";
    moduleName = if moduleNameEnv == "" then "livepatch_7" else moduleNameEnv;
  in
  assert moduleEnv != "";
  {
    name = "kernel-livepatch-nfs-transition";
    description =
      "NFS cancellation livepatch: forward and reverse transition complete "
      + "while an idle NFSv4 state manager is parked";
    tags = [ "ci" ];

    machine = import ../../machines/vpsadminos/with-empty.nix {
      inherit pkgs;
      config =
        { lib, ... }:
        {
          imports = [ ../../configs/vpsadminos/livepatch-6.12.95-boot-base.nix ];
          boot.kernelVersion = lib.mkForce "6.12.95";

          # The test loads the module itself, after the state manager parks.
          services.live-patches.enable = false;

          services.nfs.server = {
            enable = true;
            exports = ''
              /tmp 127.0.0.1(rw,fsid=0,no_subtree_check,no_root_squash,insecure)
            '';
            nfsd.allowedVersions = [
              "4"
              "4.1"
              "4.2"
            ];
          };

          environment.systemPackages = [
            pkgs.binutils
            pkgs.kmod
            pkgs.procps
            pkgs.util-linux
          ];

          environment.etc."livepatch-nfs-transition/module.ko".source = builtins.storePath moduleEnv;
        };
    };

    testScript = ''
      NFS_STATE = "/run/livepatch-nfs"
      MODULE_NAME = ${builtins.toJSON moduleName}
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

      before(:suite) do
        machine.start
        machine.wait_until_online
      end

      describe 'NFS cancellation livepatch with a parked state manager' do
        it 'activates and reverses while the NFSv4 state manager is idle' do
          # Self-cleaning start: a previous example may have left the module
          # loaded or the mount behind, which would make this run unrepresentative.
          machine.succeeds("rmmod #{MODULE_NAME} 2>/dev/null || true")
          machine.succeeds("umount -l #{NFS_STATE}/mnt 2>/dev/null || true")
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
          parked.each do |pid|
            wchan = machine.succeeds("cat /proc/#{pid}/wchan 2>/dev/null || true")[1].strip
            puts "parked task pid=#{pid} wchan=#{wchan}"
          end

          # Load the single-series cancellation module. This is the step that
          # never completes today: it must reach enabled=1, transition=0.
          machine.succeeds(
            'insmod /etc/livepatch-nfs-transition/module.ko',
            timeout: 300,
          )
          deadline = Time.now + 300
          loop do
            enabled = machine.succeeds("cat #{PATCH_DIR}/enabled 2>&1 || true")[1].strip
            transition = machine.succeeds("cat #{PATCH_DIR}/transition 2>&1 || true")[1].strip
            puts "post-insmod: enabled=#{enabled.inspect} transition=#{transition.inspect} livepatch_dir=#{machine.succeeds('ls /sys/kernel/livepatch/ 2>&1 || true')[1].strip.inspect}"
            break if enabled == '1' && transition == '0'
            raise "forward leg did not settle: enabled=#{enabled.inspect} transition=#{transition.inspect}" if Time.now > deadline
            sleep 5
          end

          # Reverse leg: a stalled transition cannot even be reversed.
          machine.succeeds("sh -c 'echo 0 > #{PATCH_DIR}/enabled'", timeout: 300)
          # Instrumented reverse leg: print the observed state every 10 s and fail
          # with the values rather than an opaque timeout.
          deadline = Time.now + 300
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
            raise "reverse leg did not settle: enabled=#{enabled.inspect} transition=#{transition.inspect} dir=#{dir_state}" if Time.now > deadline
            sleep 10
          end
          # Idempotent: in the `transition == 0` shape the module is still loaded and
          # this rmmod is what takes it out; in the gone shape it is already out.
          machine.succeeds("sh -c 'rmmod #{MODULE_NAME} 2>/dev/null || true'", timeout: 300)
          lpt_final_dir = machine.succeeds("test -e #{PATCH_DIR}/enabled && echo present || echo gone")[1].strip
          raise "module still present after the reverse leg: #{PATCH_DIR}" unless lpt_final_dir == 'gone'

          # The cancelled client must still be tearable down afterwards.
          machine.succeeds("swapoff #{NFS_STATE}/mnt/swapfile", timeout: 300)
          machine.succeeds("umount #{NFS_STATE}/mnt", timeout: 300)
        end

        it 'activates with several parked NFSv4 clients under load' do
          # Self-cleaning start, as in the first example.
          machine.succeeds("rmmod #{MODULE_NAME} 2>/dev/null || true")
          machine.succeeds("umount -l #{NFS_STATE}/mnt 2>/dev/null || true")
          # root0's "loads right on more loaded machines" axis: more than one
          # parked state manager, and a busy box, at activation time.
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

          # One of the four clients is a swap client, so its manager stays
          # resident and parked while the rest are ordinary mounts.
          machine.succeeds("dd if=/dev/zero of=#{NFS_STATE}/mnt1/swapfile bs=1M count=32", timeout: 300)
          machine.succeeds("chmod 600 #{NFS_STATE}/mnt1/swapfile")
          machine.succeeds("mkswap #{NFS_STATE}/mnt1/swapfile", timeout: 300)
          machine.succeeds("swapon #{NFS_STATE}/mnt1/swapfile", timeout: 300)

          machine.succeeds(
            "setsid sh -ec 'for i in $(seq 1 8); do (while :; do :; done) & done; " \
              "wait' >/run/livepatch-load.log 2>&1 & echo $! > /run/livepatch-load.pid"
          )
          machine.succeeds('test -s /run/livepatch-load.pid')
          expect(parked_state_manager_tasks).not_to be_empty

          machine.succeeds('insmod /etc/livepatch-nfs-transition/module.ko', timeout: 300)
          deadline = Time.now + 300
          loop do
            enabled = machine.succeeds("cat #{PATCH_DIR}/enabled 2>&1 || true")[1].strip
            transition = machine.succeeds("cat #{PATCH_DIR}/transition 2>&1 || true")[1].strip
            puts "post-insmod: enabled=#{enabled.inspect} transition=#{transition.inspect} livepatch_dir=#{machine.succeeds('ls /sys/kernel/livepatch/ 2>&1 || true')[1].strip.inspect}"
            break if enabled == '1' && transition == '0'
            raise "forward leg did not settle: enabled=#{enabled.inspect} transition=#{transition.inspect}" if Time.now > deadline
            sleep 5
          end
          machine.succeeds("sh -c 'echo 0 > #{PATCH_DIR}/enabled'", timeout: 300)
          deadline = Time.now + 300
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
            raise "reverse leg did not settle: enabled=#{enabled.inspect} transition=#{transition.inspect} dir=#{dir_state}" if Time.now > deadline
            sleep 10
          end
          # Idempotent: in the `transition == 0` shape the module is still loaded and
          # this rmmod is what takes it out; in the gone shape it is already out.
          machine.succeeds("sh -c 'rmmod #{MODULE_NAME} 2>/dev/null || true'", timeout: 300)
          lpt_final_dir = machine.succeeds("test -e #{PATCH_DIR}/enabled && echo present || echo gone")[1].strip
          raise "module still present after the reverse leg: #{PATCH_DIR}" unless lpt_final_dir == 'gone'

          machine.succeeds("swapoff #{NFS_STATE}/mnt1/swapfile", timeout: 300)
          machine.succeeds("sh -c 'kill $(cat /run/livepatch-load.pid) 2>/dev/null || true'")
          (1..4).each do |i|
            machine.succeeds("umount #{NFS_STATE}/mnt#{i}", timeout: 300)
          end
        end
      end
    '';
  }
)
