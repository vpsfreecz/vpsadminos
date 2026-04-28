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
      def self.ensure_ready
        machine.start
        machine.wait_for_osctl_pool('tank')
        machine.wait_for_osctl_pool('dozer')
        machine.wait_until_online
      end

      def self.osctl_pool_arg(pool)
        pool ? "--pool #{pool} " : ""
      end

      def self.ct_state(ctid, pool: nil)
        machine.osctl_json("#{osctl_pool_arg(pool)}ct show #{ctid}")['state']
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

      def self.expect_file(ctid, path, value, pool: nil)
        rootfs = ct_rootfs(ctid, pool:)
        _, out = machine.succeeds("cat #{File.join(rootfs, path)}")
        expect(out.strip).to eq(value)
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
        end

        after(:context) do
          cleanup_ct(ctid, target)
        end

        it 'starts the target and deletes the source during cleanup' do
          machine.succeeds(
            "osctl --pool tank ct exec #{ctid} /bin/sh -c " \
            "'mkdir -p /tmp/local-transfer && echo moved > /tmp/local-transfer/data'"
          )

          machine.all_succeed(
            "osctl --pool tank ct mv config #{ctid} #{target}",
            "osctl --pool tank ct mv rootfs #{ctid}",
            "osctl --pool tank ct mv sync #{ctid}"
          )

          machine.succeeds(
            "osctl --pool tank ct exec #{ctid} /bin/sh -c " \
            "'echo final > /tmp/local-transfer/final'"
          )

          machine.succeeds("osctl --pool tank ct mv state #{ctid}")
          wait_ct_running(target)
          machine.succeeds("osctl --pool tank ct mv cleanup #{ctid}")

          expect_ct_absent(ctid)
          expect(ct_state(target)).to eq('running')
          expect_file(target, 'tmp/local-transfer/data', 'moved')
          expect_file(target, 'tmp/local-transfer/final', 'final')
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
