import ../../make-test.nix (
  { pkgs }:
  {
    name = "osctl-ct-local-transfer";

    description = ''
      Test split local container copy and move
    '';

    tags = [ "ci" ];

    machine = {
      disks = [
        {
          type = "file";
          device = "{machine}-sda.img";
          size = "10G";
        }
        {
          type = "file";
          device = "{machine}-sdb.img";
          size = "10G";
        }
      ];

      config =
        { lib, ... }:
        {
          boot.zfs.pools = {
            tank = {
              layout = [
                { devices = [ "sda" ]; }
              ];
              importAttempts = lib.mkDefault 3;
              doCreate = true;
              install = true;
              properties."feature@block_cloning" = "disabled";
            };

            dozer = {
              layout = [
                { devices = [ "sdb" ]; }
              ];
              importAttempts = lib.mkDefault 3;
              doCreate = true;
              install = true;
              properties."feature@block_cloning" = "disabled";
            };
          };
        };
    };

    testScript = ''
      require 'shellwords'

      def self.ensure_ready
        machine.start
        machine.wait_for_osctl_pool('tank')
        machine.wait_for_osctl_pool('dozer')
        machine.wait_until_online
      end

      def self.restart_osctld
        machine.succeeds('sv -w 60 restart osctld')
        machine.wait_for_service('osctld')
        machine.wait_for_osctl_pool('tank')
        machine.wait_for_osctl_pool('dozer')
      end

      def self.osctl_pool_arg(pool)
        pool ? "--pool #{pool} " : ""
      end

      def self.ct_state(ctid, pool: nil)
        machine.osctl_json("#{osctl_pool_arg(pool)}ct show #{ctid}")['runtime_state']
      end

      def self.ct_config_state(ctid, pool: nil)
        machine.osctl_json("#{osctl_pool_arg(pool)}ct show #{ctid}")['config_state']
      end

      def self.ct_rootfs(ctid, pool: nil)
        machine.succeeds(
          "osctl #{osctl_pool_arg(pool)}ct show -H -o rootfs #{ctid}"
        )[1].strip
      end

      def self.ct_dataset(ctid, pool: nil)
        machine.succeeds(
          "osctl #{osctl_pool_arg(pool)}ct show -H -o dataset #{ctid}"
        )[1].strip
      end

      def self.ct_config_path(ctid, pool: 'tank')
        "/#{pool}/conf/ct/#{ctid}.yml"
      end

      def self.local_transfer_log_present?(ctid, pool: 'tank')
        status, = machine.execute("grep -q '^local_transfer_log:' #{ct_config_path(ctid, pool:)}")
        status == 0
      end

      def self.write_file(ctid, path, value, pool: nil)
        rootfs = ct_rootfs(ctid, pool:)
        machine.succeeds("install -d #{File.dirname(File.join(rootfs, path))}")
        machine.succeeds("printf '%s\n' #{value} > #{File.join(rootfs, path)}")
      end

      def self.write_ct_file(ctid, path, value, pool: nil)
        ct_exec(
          ctid,
          "mkdir -p /#{File.dirname(path)} && printf '%s\\n' #{value.inspect} > /#{path}",
          pool:
        )
      end

      def self.expect_file(ctid, path, value, pool: nil)
        rootfs = ct_rootfs(ctid, pool:)
        _, out = machine.succeeds("cat #{File.join(rootfs, path)}")
        expect(out.strip).to eq(value)
      end

      def self.ct_exec(ctid, command, pool: nil)
        machine.succeeds(
          "osctl #{osctl_pool_arg(pool)}ct exec #{ctid} /bin/sh -c #{command.inspect}"
        )
      end

      def self.wait_ct_exec(ctid, command, pool: nil, timeout: 120)
        machine.wait_until_succeeds(
          "osctl #{osctl_pool_arg(pool)}ct exec #{ctid} /bin/sh -c #{command.inspect}",
          timeout:
        )
      end

      def self.expect_ct_file(ctid, path, value, pool: nil)
        _, out = ct_exec(ctid, "cat /#{path}", pool:)
        expect(out.strip).to eq(value)
      end

      def self.install_test_service(ctid, value, pool: nil)
        rootfs = ct_rootfs(ctid, pool:)

        machine.succeeds(<<~CMD)
          cat > #{rootfs}/etc/init.d/transfer-service <<'EOF'
          #!/sbin/openrc-run
          command="/bin/sleep"
          command_args="2147483647"
          command_background="yes"
          pidfile="/run/transfer-service.pid"

          start_pre() {
            printf '%s\\n' #{value.inspect} > /run/transfer-service.value
          }
          EOF
          chmod +x #{rootfs}/etc/init.d/transfer-service
        CMD

        ct_exec(ctid, 'rc-update add transfer-service default', pool:)
        ct_exec(ctid, 'rc-service transfer-service start', pool:)
        expect_test_service(ctid, value, pool:)
      end

      def self.expect_test_service(ctid, value, pool: nil)
        wait_ct_exec(ctid, 'rc-service transfer-service status', pool:, timeout: 60)
        _, out = wait_ct_exec(ctid, 'cat /run/transfer-service.value', pool:, timeout: 60)
        expect(out.strip).to eq(value)
      end

      def self.hook_path(ctid, hook_name, pool: 'tank')
        "/#{pool}/hook/ct/#{ctid}/#{hook_name}"
      end

      def self.install_hook(ctid, hook_name, script, pool: 'tank')
        path = hook_path(ctid, hook_name, pool:)

        machine.succeeds(<<~CMD)
          install -d -m 700 #{Shellwords.escape(File.dirname(path))}
          cat > #{Shellwords.escape(path)} <<'EOF'
          #{script}
          EOF
          chmod 700 #{Shellwords.escape(path)}
        CMD
      end

      def self.remove_hook(ctid, hook_name, pool: 'tank')
        machine.succeeds("rm -f #{Shellwords.escape(hook_path(ctid, hook_name, pool:))}")
      end

      def self.transfer_snapshots(dataset)
        machine.succeeds(
          "zfs list -H -t snapshot -o name -r #{dataset} " \
          "| grep -E 'osctl-(copy|move)' || true"
        )[1]
      end

      def self.expect_no_transfer_snapshots(ctid, pool: nil)
        dataset = ct_dataset(ctid, pool:)
        expect(transfer_snapshots(dataset)).to eq("")
      end

      def self.expect_ct_absent(ctid, pool: nil, timeout: 60)
        wait_until_block_fails(name: "#{ctid} disappears", timeout: timeout) do
          machine.succeeds("osctl #{osctl_pool_arg(pool)}ct show #{ctid}")
        end
      end

      def self.wait_ct_running(ctid, pool: nil)
        wait_for_block(name: "#{ctid} becomes running", timeout: 120) do
          state = ct_state(ctid, pool:)
          next false unless state == 'running'

          state
        end

        machine.wait_until_succeeds(
          "osctl #{osctl_pool_arg(pool)}ct exec #{ctid} true",
          timeout: 120
        )
      end

      def self.cleanup_ct(*ctids)
        ctids.each do |ctid|
          [nil, 'dozer'].each do |pool|
            machine.succeeds(
              "osctl #{osctl_pool_arg(pool)}ct del -f --prune #{ctid} >/dev/null 2>&1 || true"
            )
          end
        end
      end

      def self.cleanup_user(pool, user)
        machine.succeeds("osctl #{osctl_pool_arg(pool)}user del #{user} >/dev/null 2>&1 || true")
      end

      configure_examples do |config|
        config.default_order = :defined
      end

      ensure_ready

      describe 'split local copy' do
        ctid = "#{get_container_id}-copy-src"
        target = "#{ctid}-dst"

        before(:context) do
          cleanup_ct(ctid, target)
          machine.all_succeed(
            "osctl --pool tank ct new --distribution alpine #{ctid}",
            "osctl --pool tank ct unset start-menu #{ctid}"
          )
        end

        after(:context) do
          cleanup_ct(ctid, target)
        end

        it 'copies rootfs, repeated changes and state, then cleans up' do
          write_file(ctid, 'tmp/local-transfer/base', 'base')

          machine.all_succeed(
            "osctl --pool tank ct cp config #{ctid} #{target}",
            "osctl --pool tank ct cp rootfs #{ctid}"
          )

          write_file(ctid, 'tmp/local-transfer/sync', 'sync')
          machine.succeeds("osctl --pool tank ct cp sync #{ctid}")

          write_file(ctid, 'tmp/local-transfer/state', 'state')
          machine.all_succeed(
            "osctl --pool tank ct cp state #{ctid}",
            "osctl --pool tank ct cp cleanup #{ctid}"
          )

          expect(ct_state(ctid)).not_to eq('missing')
          expect(ct_state(target)).to eq('stopped')
          expect_file(target, 'tmp/local-transfer/base', 'base')
          expect_file(target, 'tmp/local-transfer/sync', 'sync')
          expect_file(target, 'tmp/local-transfer/state', 'state')
          machine.succeeds("osctl --pool tank ct start #{target}")
          wait_ct_running(target)
          expect_ct_file(target, 'tmp/local-transfer/base', 'base')
          expect_ct_file(target, 'tmp/local-transfer/sync', 'sync')
          expect_ct_file(target, 'tmp/local-transfer/state', 'state')
          expect(local_transfer_log_present?(ctid)).to be(false)
          expect_no_transfer_snapshots(ctid)
          expect_no_transfer_snapshots(target)
        end
      end

      describe 'all-in-one local copy' do
        ctid = "#{get_container_id}-copy-once-src"
        target = "#{ctid}-dst"

        before(:context) do
          cleanup_ct(ctid, target)
          machine.all_succeed(
            "osctl --pool tank ct new --distribution alpine #{ctid}",
            "osctl --pool tank ct unset start-menu #{ctid}"
          )
        end

        after(:context) do
          cleanup_ct(ctid, target)
        end

        it 'runs all split phases and leaves no transfer state behind' do
          write_file(ctid, 'tmp/local-transfer/all-in-one-copy', 'copied')

          machine.succeeds("osctl --pool tank ct cp #{ctid} #{target}")

          expect(ct_state(ctid)).to eq('stopped')
          expect(ct_state(target)).to eq('stopped')
          expect_file(target, 'tmp/local-transfer/all-in-one-copy', 'copied')
          machine.succeeds("osctl --pool tank ct start #{target}")
          wait_ct_running(target)
          expect_ct_file(target, 'tmp/local-transfer/all-in-one-copy', 'copied')
          expect(local_transfer_log_present?(ctid)).to be(false)
          expect_no_transfer_snapshots(ctid)
          expect_no_transfer_snapshots(target)
        end
      end

      describe 'running split local copy' do
        ctid = "#{get_container_id}-run-copy"
        target = "#{ctid}-dst"

        before(:context) do
          cleanup_ct(ctid, target)
          machine.all_succeed(
            "osctl --pool tank ct new --distribution alpine #{ctid}",
            "osctl --pool tank ct unset start-menu #{ctid}",
            "osctl --pool tank ct start #{ctid}"
          )
          wait_ct_running(ctid)
          install_test_service(ctid, 'copy-service')
        end

        after(:context) do
          cleanup_ct(ctid, target)
        end

        it 'keeps the source running outside the final snapshot window' do
          machine.all_succeed(
            "osctl --pool tank ct cp config #{ctid} #{target}",
            "osctl --pool tank ct cp rootfs #{ctid}",
            "osctl --pool tank ct cp sync #{ctid}"
          )

          expect(ct_state(ctid)).to eq('running')

          machine.succeeds("osctl --pool tank ct cp state #{ctid}")

          wait_ct_running(ctid)
          machine.succeeds("osctl --pool tank ct cp cleanup #{ctid}")
          expect(ct_state(ctid)).to eq('running')
          expect_test_service(ctid, 'copy-service')

          machine.succeeds("osctl --pool tank ct start #{target}")
          wait_ct_running(target)
          expect_test_service(target, 'copy-service')
        end
      end

      describe 'running split local copy with osctld restarts' do
        ctid = "#{get_container_id}-copy-restart"
        target = "#{ctid}-dst"

        before(:context) do
          cleanup_ct(ctid, target)
          machine.all_succeed(
            "osctl --pool tank ct new --distribution alpine #{ctid}",
            "osctl --pool tank ct unset start-menu #{ctid}",
            "osctl --pool tank ct start #{ctid}"
          )
          wait_ct_running(ctid)
          install_test_service(ctid, 'copy-restart-service')
        end

        after(:context) do
          cleanup_ct(ctid, target)
        end

        it 'persists and reloads the local copy state between phases' do
          transfer_files = {
            'tmp/local-transfer/copy-restart-base' => 'copy-restart-base',
            'tmp/local-transfer/copy-restart-sync' => 'copy-restart-sync',
            'tmp/local-transfer/copy-restart-state' => 'copy-restart-state'
          }

          write_ct_file(ctid, 'tmp/local-transfer/copy-restart-base', 'copy-restart-base')

          machine.succeeds("osctl --pool tank ct cp config #{ctid} #{target}")
          restart_osctld

          wait_ct_running(ctid)
          expect(ct_config_state(target)).to eq('staged')
          expect(ct_state(target)).to eq('stopped')
          expect(local_transfer_log_present?(ctid)).to be(true)

          machine.succeeds("osctl --pool tank ct cp rootfs #{ctid}")
          restart_osctld

          wait_ct_running(ctid)
          expect(ct_config_state(target)).to eq('staged')
          expect(ct_state(target)).to eq('stopped')
          expect(local_transfer_log_present?(ctid)).to be(true)

          write_ct_file(ctid, 'tmp/local-transfer/copy-restart-sync', 'copy-restart-sync')
          machine.succeeds("osctl --pool tank ct cp sync #{ctid}")
          restart_osctld

          wait_ct_running(ctid)
          expect(ct_config_state(target)).to eq('staged')
          expect(ct_state(target)).to eq('stopped')
          expect(local_transfer_log_present?(ctid)).to be(true)

          write_ct_file(ctid, 'tmp/local-transfer/copy-restart-state', 'copy-restart-state')
          machine.succeeds("osctl --pool tank ct cp state #{ctid}")
          restart_osctld

          expect(ct_state(target)).to eq('stopped')
          expect(local_transfer_log_present?(ctid)).to be(true)

          machine.succeeds("osctl --pool tank ct cp cleanup #{ctid}")

          if ct_state(ctid) != 'running'
            machine.succeeds("osctl --pool tank ct start #{ctid}")
          end

          wait_ct_running(ctid)
          expect_test_service(ctid, 'copy-restart-service')

          machine.succeeds("osctl --pool tank ct start #{target}")
          wait_ct_running(target)
          expect_ct_file(target, 'tmp/local-transfer/copy-restart-base', 'copy-restart-base')
          expect_ct_file(target, 'tmp/local-transfer/copy-restart-sync', 'copy-restart-sync')
          expect_ct_file(target, 'tmp/local-transfer/copy-restart-state', 'copy-restart-state')
          expect_test_service(target, 'copy-restart-service')
          expect(local_transfer_log_present?(ctid)).to be(false)
          expect_no_transfer_snapshots(ctid)
          expect_no_transfer_snapshots(target)
        end
      end

      describe 'running local copy state retry' do
        ctid = "#{get_container_id}-copy-retry"
        target = "#{ctid}-dst"

        before(:context) do
          cleanup_ct(ctid, target)
          machine.all_succeed(
            "osctl --pool tank ct new --distribution alpine #{ctid}",
            "osctl --pool tank ct unset start-menu #{ctid}",
            "osctl --pool tank ct start #{ctid}"
          )
          wait_ct_running(ctid)
          install_test_service(ctid, 'copy-retry-service')
          machine.all_succeed(
            "osctl --pool tank ct cp config #{ctid} #{target}",
            "osctl --pool tank ct cp rootfs #{ctid}",
            "osctl --pool tank ct cp sync #{ctid}"
          )
          install_hook(ctid, 'pre-stop', <<~HOOK)
            #!/bin/sh
            exit 1
          HOOK
        end

        after(:context) do
          remove_hook(ctid, 'pre-stop')
          cleanup_ct(ctid, target)
        end

        it 'can retry after source stop fails' do
          ct_exec(
            ctid,
            'mkdir -p /tmp/local-transfer && echo before-retry > /tmp/local-transfer/before-retry'
          )

          machine.fails("osctl --pool tank ct cp state #{ctid}")

          expect(ct_state(ctid)).to eq('running')
          expect(ct_config_state(target)).to eq('staged')
          expect(ct_state(target)).to eq('unknown')
          expect(local_transfer_log_present?(ctid)).to be(true)

          remove_hook(ctid, 'pre-stop')
          machine.succeeds("osctl --pool tank ct cp state #{ctid}")

          wait_ct_running(ctid)
          expect_test_service(ctid, 'copy-retry-service')
          machine.succeeds("osctl --pool tank ct cp cleanup #{ctid}")

          machine.succeeds("osctl --pool tank ct start #{target}")
          wait_ct_running(target)
          expect_ct_file(target, 'tmp/local-transfer/before-retry', 'before-retry')
          expect_test_service(target, 'copy-retry-service')
          expect(local_transfer_log_present?(ctid)).to be(false)
          expect_no_transfer_snapshots(ctid)
          expect_no_transfer_snapshots(target)
        end
      end

      describe 'split local move' do
        ctid = "#{get_container_id}-move-src"
        target = "#{ctid}-dst"

        before(:context) do
          cleanup_ct(ctid, target)
          machine.all_succeed(
            "osctl --pool tank ct new --distribution alpine #{ctid}",
            "osctl --pool tank ct unset start-menu #{ctid}",
            "osctl --pool tank ct start #{ctid}"
          )
          wait_ct_running(ctid)
          install_test_service(ctid, 'move-service')
        end

        after(:context) do
          cleanup_ct(ctid, target)
        end

        it 'starts the target and deletes the source during cleanup' do
          machine.succeeds(
            "osctl --pool tank ct exec #{ctid} /bin/sh -c " \
            "'mkdir -p /tmp/local-transfer && echo before > /tmp/local-transfer/before'"
          )
          expect_test_service(ctid, 'move-service')

          machine.all_succeed(
            "osctl --pool tank ct mv config #{ctid} #{target}",
            "osctl --pool tank ct mv rootfs #{ctid}"
          )

          ct_exec(ctid, 'echo after-rootfs > /tmp/local-transfer/after-rootfs')
          machine.succeeds("osctl --pool tank ct mv sync #{ctid}")

          ct_exec(ctid, 'echo after-sync > /tmp/local-transfer/after-sync')

          machine.succeeds("osctl --pool tank ct mv state #{ctid}")
          wait_ct_running(target)
          machine.succeeds("osctl --pool tank ct mv cleanup #{ctid}")

          expect_ct_absent(ctid)
          expect(ct_state(target)).to eq('running')
          expect_ct_file(target, 'tmp/local-transfer/before', 'before')
          expect_ct_file(target, 'tmp/local-transfer/after-rootfs', 'after-rootfs')
          expect_ct_file(target, 'tmp/local-transfer/after-sync', 'after-sync')
          expect_test_service(target, 'move-service')
          expect_no_transfer_snapshots(target)
        end
      end

      describe 'running split local move with osctld restarts' do
        ctid = "#{get_container_id}-move-restart"
        target = "#{ctid}-dst"

        before(:context) do
          cleanup_ct(ctid, target)
          machine.all_succeed(
            "osctl --pool tank ct new --distribution alpine #{ctid}",
            "osctl --pool tank ct unset start-menu #{ctid}",
            "osctl --pool tank ct start #{ctid}"
          )
          wait_ct_running(ctid)
          install_test_service(ctid, 'move-restart-service')
        end

        after(:context) do
          cleanup_ct(ctid, target)
        end

        it 'persists and reloads the local move state between phases' do
          write_ct_file(ctid, 'tmp/local-transfer/move-restart-base', 'move-restart-base')

          machine.succeeds("osctl --pool tank ct mv config #{ctid} #{target}")
          restart_osctld

          wait_ct_running(ctid)
          expect(ct_config_state(target)).to eq('staged')
          expect(ct_state(target)).to eq('stopped')
          expect(local_transfer_log_present?(ctid)).to be(true)

          machine.succeeds("osctl --pool tank ct mv rootfs #{ctid}")
          restart_osctld

          wait_ct_running(ctid)
          expect(ct_config_state(target)).to eq('staged')
          expect(ct_state(target)).to eq('stopped')
          expect(local_transfer_log_present?(ctid)).to be(true)

          write_ct_file(ctid, 'tmp/local-transfer/move-restart-sync', 'move-restart-sync')
          machine.succeeds("osctl --pool tank ct mv sync #{ctid}")
          restart_osctld

          wait_ct_running(ctid)
          expect(ct_config_state(target)).to eq('staged')
          expect(ct_state(target)).to eq('stopped')
          expect(local_transfer_log_present?(ctid)).to be(true)

          write_ct_file(ctid, 'tmp/local-transfer/move-restart-state', 'move-restart-state')
          machine.succeeds("osctl --pool tank ct mv state #{ctid}")
          restart_osctld

          wait_ct_running(target)
          expect(ct_state(ctid)).to eq('stopped')
          expect(local_transfer_log_present?(ctid)).to be(true)

          machine.succeeds("osctl --pool tank ct mv cleanup #{ctid}")

          expect_ct_absent(ctid)
          expect(ct_state(target)).to eq('running')
          expect_ct_file(target, 'tmp/local-transfer/move-restart-base', 'move-restart-base')
          expect_ct_file(target, 'tmp/local-transfer/move-restart-sync', 'move-restart-sync')
          expect_ct_file(target, 'tmp/local-transfer/move-restart-state', 'move-restart-state')
          expect_test_service(target, 'move-restart-service')
          expect_no_transfer_snapshots(target)
        end
      end

      describe 'running local move state retry' do
        ctid = "#{get_container_id}-move-retry"
        target = "#{ctid}-dst"

        before(:context) do
          cleanup_ct(ctid, target)
          machine.all_succeed(
            "osctl --pool tank ct new --distribution alpine #{ctid}",
            "osctl --pool tank ct unset start-menu #{ctid}",
            "osctl --pool tank ct start #{ctid}"
          )
          wait_ct_running(ctid)
          install_test_service(ctid, 'move-retry-service')
          machine.all_succeed(
            "osctl --pool tank ct mv config #{ctid} #{target}",
            "osctl --pool tank ct mv rootfs #{ctid}",
            "osctl --pool tank ct mv sync #{ctid}"
          )
          install_hook(target, 'pre-start', <<~HOOK)
            #!/bin/sh
            exit 1
          HOOK
        end

        after(:context) do
          remove_hook(target, 'pre-start')
          cleanup_ct(ctid, target)
        end

        it 'can retry after target start fails' do
          ct_exec(
            ctid,
            'mkdir -p /tmp/local-transfer && echo before-retry > /tmp/local-transfer/before-retry'
          )

          machine.fails("osctl --pool tank ct mv state #{ctid}")

          expect(ct_state(ctid)).to eq('stopped')
          expect(ct_state(target)).to eq('stopped')
          expect(local_transfer_log_present?(ctid)).to be(true)

          remove_hook(target, 'pre-start')
          machine.succeeds("osctl --pool tank ct mv state #{ctid}")

          wait_ct_running(target)
          machine.succeeds("osctl --pool tank ct mv cleanup #{ctid}")

          expect_ct_absent(ctid)
          expect(ct_state(target)).to eq('running')
          expect_ct_file(target, 'tmp/local-transfer/before-retry', 'before-retry')
          expect_test_service(target, 'move-retry-service')
          expect_no_transfer_snapshots(target)
        end
      end

      describe 'all-in-one local move' do
        ctid = "#{get_container_id}-move-once-src"
        target = "#{ctid}-dst"

        before(:context) do
          cleanup_ct(ctid, target)
          machine.all_succeed(
            "osctl --pool tank ct new --distribution alpine #{ctid}",
            "osctl --pool tank ct unset start-menu #{ctid}"
          )
        end

        after(:context) do
          cleanup_ct(ctid, target)
        end

        it 'runs all split phases and deletes the source' do
          write_file(ctid, 'tmp/local-transfer/all-in-one-move', 'moved')

          machine.succeeds("osctl --pool tank ct mv #{ctid} #{target}")

          expect_ct_absent(ctid)
          expect(ct_state(target)).to eq('stopped')
          expect_file(target, 'tmp/local-transfer/all-in-one-move', 'moved')
          machine.succeeds("osctl --pool tank ct start #{target}")
          wait_ct_running(target)
          expect_ct_file(target, 'tmp/local-transfer/all-in-one-move', 'moved')
          expect_no_transfer_snapshots(target)
        end
      end

      describe 'split local move to another pool' do
        ctid = "#{get_container_id}-pool-move-src"
        target = "#{ctid}-dst"

        before(:context) do
          cleanup_ct(ctid, target)
          cleanup_user('dozer', ctid)
          machine.all_succeed(
            "osctl --pool tank ct new --distribution alpine #{ctid}",
            "osctl --pool tank ct unset start-menu #{ctid}",
            "osctl --pool dozer user new #{ctid}"
          )
        end

        after(:context) do
          cleanup_ct(ctid, target)
          cleanup_user('dozer', ctid)
        end

        it 'creates the target on the requested pool' do
          write_file(ctid, 'tmp/local-transfer/cross-pool', 'dozer')

          machine.all_succeed(
            "osctl --pool tank ct mv config --pool dozer #{ctid} #{target}",
            "osctl --pool tank ct mv rootfs #{ctid}",
            "osctl --pool tank ct mv state --no-start #{ctid}",
            "osctl --pool tank ct mv cleanup #{ctid}"
          )

          expect_ct_absent(ctid)
          expect(ct_state(target, pool: 'dozer')).to eq('stopped')
          expect(ct_dataset(target, pool: 'dozer')).to start_with('dozer/')
          expect_file(target, 'tmp/local-transfer/cross-pool', 'dozer', pool: 'dozer')
          machine.succeeds("osctl --pool dozer ct start #{target}")
          wait_ct_running(target, pool: 'dozer')
          expect_ct_file(target, 'tmp/local-transfer/cross-pool', 'dozer', pool: 'dozer')
          expect_no_transfer_snapshots(target, pool: 'dozer')
        end
      end

      describe 'local copy cancel' do
        ctid = "#{get_container_id}-cancel"
        target = "#{ctid}-dst"

        before(:context) do
          cleanup_ct(ctid, target)
          machine.all_succeed(
            "osctl --pool tank ct new --distribution alpine #{ctid}",
            "osctl --pool tank ct unset start-menu #{ctid}"
          )
        end

        after(:context) do
          cleanup_ct(ctid, target)
        end

        it 'removes the staged target and transfer log' do
          write_file(ctid, 'tmp/local-transfer/base', 'base')

          machine.all_succeed(
            "osctl --pool tank ct cp config #{ctid} #{target}",
            "osctl --pool tank ct cp rootfs #{ctid}",
            "osctl --pool tank ct cp cancel #{ctid}"
          )

          expect(ct_state(ctid)).to eq('stopped')
          expect_ct_absent(target)
          expect(local_transfer_log_present?(ctid)).to be(false)
          expect_no_transfer_snapshots(ctid)
        end
      end
    '';
  }
)
