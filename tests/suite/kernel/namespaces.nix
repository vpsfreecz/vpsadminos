import ../../make-test.nix (
  { pkgs }:
  let
    mkNamespaceContainer = {
      user = "testuser";

      shareStore = true;

      autostart.enable = true;

      startMenu.enable = false;

      config = { config, ... }: {
        documentation.enable = false;
        documentation.nixos.enable = false;
      };
    };

    mkNamespacePool =
      ctName:
      {
        osctl.pools.tank = {
          users.testuser = {
            uidMap = [ "0:500000:65536" ];
            gidMap = [ "0:600000:65536" ];
          };

          containers.${ctName} = mkNamespaceContainer;
        };
      };

    qemuConfig = lib: {
      boot.qemu = {
        memory = lib.mkForce 4096;
        cpus = lib.mkForce 1;
        cpu = {
          cores = lib.mkForce 1;
          threads = lib.mkForce 1;
          sockets = lib.mkForce 1;
        };
      };
    };

    plainMachine =
      (import ../../machines/vpsadminos/with-tank.nix {
        inherit pkgs;
        config =
          { lib, ... }:
          lib.mkMerge [
            (mkNamespacePool "plain-ns")
            (qemuConfig lib)
          ];
      })
      // {
        # Exercise LXC's AppArmor handling while keeping osctld AppArmor disabled.
        kernelParams = [ "apparmor=1" ];
      };

    apparmorMachine =
      (import ../../machines/vpsadminos/with-tank.nix {
        inherit pkgs;
        config =
          { lib, pkgs, ... }:
          lib.mkMerge [
            (mkNamespacePool "aa-ns")
            (qemuConfig lib)
            {
              security.apparmor = {
                enable = true;
                enableOnBoot = true;
                packages = [ pkgs.lxc ];
              };
            }
          ];
      })
      // {
        kernelParams = [
          "apparmor=1"
          "apparmor.root_ns_policy=1"
        ];
      };
  in
  {
    name = "kernel-namespaces";

    description = ''
      Test vpsAdminOS kernel namespaces used by LXC containers
    '';

    tags = [ "ci" ];

    machines = {
      plain = plainMachine;
      apparmor = apparmorMachine;
    };

    testScript = ''
      def self.ns_link(machine, path)
        machine.succeeds("readlink #{path}")[1].strip
      end

      def self.ct_init_pid(machine, testct)
        pid = (container_status(machine, testct)&.fetch('init_pid', nil) || 0).to_i
        expect(pid).to be > 1
        pid
      end

      def self.container_status(machine, testct)
        status, output = machine.execute("osctl -j ct show #{testct}", timeout: 60)
        return nil if status != 0

        JSON.parse(output)
      end

      def self.lxc_config(machine, testct)
        lxc_dir = machine.osctl_json("ct show #{testct}")['lxc_dir']
        machine.succeeds("cat #{lxc_dir}/config")[1]
      end

      def self.dump_container_debug(machine, testct)
        machine.execute(<<~SH, timeout: 120)
          echo '--- container state ---'
          osctl ct show #{testct} || true
          echo '--- pool history ---'
          osctl history tank || true
          echo '--- container log ---'
          osctl ct log cat #{testct} || true
          echo '--- generated lxc config ---'
          lxc_dir="$(osctl -j ct show #{testct} | ruby -rjson -e 'puts JSON.parse($stdin.read).fetch("lxc_dir")' 2>/dev/null || true)"
          if [ -n "$lxc_dir" ] && [ -f "$lxc_dir/config" ]; then
            cat "$lxc_dir/config"
          fi
          echo '--- namespace processes ---'
          ps -ef | grep -E 'lxc|osctld-ct|#{testct}' | grep -v grep || true
          lsns || true
          echo '--- recent osctld logs ---'
          find /var/log -maxdepth 3 -type f -name '*osctld*' -print -exec tail -n 500 {} \\; || true
        SH
      end

      def self.ct_exec_succeeds(machine, testct, cmd, timeout: 120)
        status, output = machine.execute("osctl ct exec #{testct} #{cmd}", timeout: timeout)
        return output if status == 0

        _, debug_output = dump_container_debug(machine, testct)
        fail "osctl ct exec #{testct} #{cmd.inspect} failed with status #{status}:\n#{output}\n#{debug_output}"
      end

      def self.ct_attach_ns(machine, testct, ns)
        status, output = machine.execute(
          "printf 'readlink /proc/self/ns/#{ns}\\nexit 0\\n' | timeout 60 osctl ct attach --user-shell #{testct}",
          timeout: 120
        )

        match = output.match(/#{Regexp.escape(ns)}:\[\d+\]/)
        return match[0] if match

        if status != 0
          _, debug_output = dump_container_debug(machine, testct)
          fail "osctl ct attach --user-shell #{testct} failed with status #{status}:\n#{output}\n#{debug_output}"
        end

        fail "unable to find #{ns} namespace in ct attach output:\n#{output}"
      end

      def self.ensure_container_started(machine, testct)
        deadline = Time.now + 8 * 60
        stopped_since = nil

        loop do
          ct_status = container_status(machine, testct)
          current_state = ct_status&.fetch('state', nil)
          init_pid = (ct_status&.fetch('init_pid', nil) || 0).to_i

          return if current_state == 'running' && init_pid > 1

          if current_state == 'stopped'
            stopped_since ||= Time.now
            break if Time.now - stopped_since >= 60
          else
            stopped_since = nil
          end

          break if Time.now >= deadline
          sleep(1)
        end

        ct_status = container_status(machine, testct)

        if ct_status && ct_status['state'] != 'running'
          status, output = machine.execute("osctl ct start --debug --wait 60 #{testct}", timeout: 180)
          return if status == 0 && (container_status(machine, testct)&.fetch('init_pid', nil) || 0).to_i > 1
        elsif ct_status
          output = "container #{testct} is #{ct_status['state']} without init_pid > 1: #{ct_status.inspect}"
        else
          output = "container #{testct} did not become visible"
        end

        _, debug_output = dump_container_debug(machine, testct)
        fail "failed to start #{testct}:\n#{output}\n#{debug_output}"
      end

      def self.tracing_supported?(machine)
        machine.execute("test -e /proc/self/ns/tracing")[0] == 0
      end

      def self.syslog_supported?(machine)
        machine.execute("test -e /proc/self/ns/syslog")[0] == 0
      end

      def self.apparmor_lsm_supported?(machine)
        machine.execute(<<~'SH')[0] == 0
          test -e /proc/self/ns/lsm &&
            test "$(cat /sys/module/apparmor/parameters/enabled 2>/dev/null | tr A-Z a-z)" = y
        SH
      end

      def self.apparmor_lsm_support_report(machine)
        machine.execute(<<~'SH', timeout: 60)[1]
          set +e
          echo "/proc/self/ns/lsm:"
          readlink /proc/self/ns/lsm
          echo "securityfs lsm:"
          cat /sys/kernel/security/lsm
          echo "apparmor securityfs:"
          ls -la /sys/kernel/security/apparmor
          echo "apparmor parser-visible securityfs is optional when kernfs_filter restricts /sys"
          echo "apparmor enabled:"
          cat /sys/module/apparmor/parameters/enabled
        SH
      end

      before(:suite) do
        machines.each_value(&:start)
        machines.each_value(&:wait_until_online)
        machines.each_value { |machine| machine.wait_for_osctl_pool('tank', timeout: 8 * 60) }
        ensure_container_started(plain, 'plain-ns')
        ensure_container_started(apparmor, 'aa-ns')
      end

      describe 'default AppArmor-disabled system' do
        before(:context) do
          @testct = 'plain-ns'
          @tracing_supported = tracing_supported?(plain)
          @syslog_supported = syslog_supported?(plain)
          @lsm_supported = apparmor_lsm_supported?(plain)
        end

        it 'disables LXC AppArmor defaults even when kernel AppArmor is present' do
          skip 'AppArmor LSM is not present on this kernel' unless @lsm_supported

          expect(lxc_config(plain, @testct)).to include("lxc.apparmor.profile = unconfined\n")
        end

        it 'creates a dedicated tracing namespace when supported' do
          skip 'tracing namespace is not supported by this kernel' unless @tracing_supported

          init_pid = ct_init_pid(plain, @testct)
          host_ns = ns_link(plain, '/proc/self/ns/tracing')
          init_ns = ns_link(plain, "/proc/#{init_pid}/ns/tracing")
          exec_ns = ct_exec_succeeds(plain, @testct, 'readlink /proc/self/ns/tracing').strip
          attach_ns = ct_attach_ns(plain, @testct, 'tracing')

          expect(init_ns).not_to eq(host_ns)
          expect(exec_ns).to eq(init_ns)
          expect(attach_ns).to eq(init_ns)
        end

        it 'keeps ct exec inside the container syslog namespace when supported' do
          skip 'syslog namespace is not supported by this kernel' unless @syslog_supported

          init_pid = ct_init_pid(plain, @testct)
          host_ns = ns_link(plain, '/proc/self/ns/syslog')
          init_ns = ns_link(plain, "/proc/#{init_pid}/ns/syslog")
          exec_ns = ct_exec_succeeds(plain, @testct, 'readlink /proc/self/ns/syslog').strip
          attach_ns = ct_attach_ns(plain, @testct, 'syslog')

          expect(init_ns).not_to eq(host_ns)
          expect(exec_ns).to eq(init_ns)
          expect(attach_ns).to eq(init_ns)
        end
      end

      describe 'AppArmor-enabled system' do
        before(:context) do
          @testct = 'aa-ns'
          @tracing_supported = tracing_supported?(apparmor)
          @syslog_supported = syslog_supported?(apparmor)
          @lsm_supported = apparmor_lsm_supported?(apparmor)
        end

        it 'has AppArmor LSM namespace support enabled' do
          expect(@lsm_supported).to be(true), apparmor_lsm_support_report(apparmor)
        end

        it 'uses LXC-managed AppArmor LSM namespace cloning when supported' do
          skip 'AppArmor LSM namespace is not supported by this kernel' unless @lsm_supported

          config = lxc_config(apparmor, @testct)

          expect(config).to include("lxc.namespace.clone.lsm = apparmor\n")
          expect(config).to include("lxc.namespace.clone.lsm.name = lxc-ct-tank-aa-ns\n")
          expect(config).to include("lxc.apparmor.profile = unchanged\n")
        end

        it 'creates a dedicated AppArmor LSM namespace when supported' do
          skip 'AppArmor LSM namespace is not supported by this kernel' unless @lsm_supported

          init_pid = ct_init_pid(apparmor, @testct)
          host_ns = ns_link(apparmor, '/proc/self/ns/lsm')
          init_ns = ns_link(apparmor, "/proc/#{init_pid}/ns/lsm")
          exec_ns = ct_exec_succeeds(apparmor, @testct, 'readlink /proc/self/ns/lsm').strip
          attach_ns = ct_attach_ns(apparmor, @testct, 'lsm')

          expect(init_ns).not_to eq(host_ns)
          expect(exec_ns).to eq(init_ns)
          expect(attach_ns).to eq(init_ns)
        end

        it 'creates a dedicated tracing namespace when supported' do
          skip 'tracing namespace is not supported by this kernel' unless @tracing_supported

          init_pid = ct_init_pid(apparmor, @testct)
          host_ns = ns_link(apparmor, '/proc/self/ns/tracing')
          init_ns = ns_link(apparmor, "/proc/#{init_pid}/ns/tracing")
          exec_ns = ct_exec_succeeds(apparmor, @testct, 'readlink /proc/self/ns/tracing').strip
          attach_ns = ct_attach_ns(apparmor, @testct, 'tracing')

          expect(init_ns).not_to eq(host_ns)
          expect(exec_ns).to eq(init_ns)
          expect(attach_ns).to eq(init_ns)
        end

        it 'keeps ct exec inside the container syslog namespace when supported' do
          skip 'syslog namespace is not supported by this kernel' unless @syslog_supported

          init_pid = ct_init_pid(apparmor, @testct)
          host_ns = ns_link(apparmor, '/proc/self/ns/syslog')
          init_ns = ns_link(apparmor, "/proc/#{init_pid}/ns/syslog")
          exec_ns = ct_exec_succeeds(apparmor, @testct, 'readlink /proc/self/ns/syslog').strip
          attach_ns = ct_attach_ns(apparmor, @testct, 'syslog')

          expect(init_ns).not_to eq(host_ns)
          expect(exec_ns).to eq(init_ns)
          expect(attach_ns).to eq(init_ns)
        end
      end
    '';
  }
)
