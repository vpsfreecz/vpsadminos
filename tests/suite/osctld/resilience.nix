import ../../make-test.nix (
  { pkgs }:
  {
    name = "osctld-resilience";

    description = ''
      Test osctld resilience to unexpected container state
    '';

    tags = [ "ci" ];

    machine = import ../../machines/vpsadminos/tank.nix pkgs;

    testScript = ''
      require 'shellwords'

      OSCTLD_SOCKET = '/run/osctl/osctld.sock'

      ctid = get_container_id('missing-rootfs')

      configure_examples do |config|
        config.default_order = :defined
      end

      def self.output_of(command)
        machine.succeeds(command)[1].strip
      end

      def self.wait_osctld_ready
        machine.wait_for_service('osctld')
        machine.wait_until_succeeds("test -S #{OSCTLD_SOCKET}", timeout: 60)
        machine.wait_for_osctl_pool('tank')
        machine.succeeds('osctl daemon wait-ready --timeout 60')
      end

      def self.restart_osctld
        machine.succeeds('sv -w 60 restart osctld')
        wait_osctld_ready
      end

      def self.ct_runtime_state(ctid)
        machine.osctl_json("ct show #{ctid}")['runtime_state']
      end

      def self.ct_info(ctid)
        machine.osctl_json("ct show #{ctid}")
      end

      def self.ct_dataset(ctid)
        output_of("osctl ct show -H -o dataset #{Shellwords.escape(ctid)}")
      end

      def self.shared_dir_path(ctid)
        "/run/osctl/pools/tank/mounts/#{ctid}"
      end

      def self.wait_ct_running(ctid)
        wait_for_block(name: "#{ctid} becomes running", timeout: 120) do
          ct_runtime_state(ctid) == 'running'
        end

        machine.wait_until_succeeds("osctl ct exec #{Shellwords.escape(ctid)} true", timeout: 120)
      end

      def self.trash_dataset(dataset)
        escaped_dataset = Shellwords.escape(dataset)
        trashed_dataset = "#{dataset}-trashed"
        escaped_trashed_dataset = Shellwords.escape(trashed_dataset)

        machine.succeeds(<<~SH)
          set -eu
          zfs destroy -r -f #{escaped_trashed_dataset} >/dev/null 2>&1 || true
          zfs rename -u #{escaped_dataset} #{escaped_trashed_dataset}
          ! zfs list -H #{escaped_dataset}
        SH

        trashed_dataset
      end

      def self.expect_osctld_operational
        machine.succeeds("test -S #{OSCTLD_SOCKET}")
        machine.succeeds('osctl pool ls')
      end

      before(:suite) do
        machine.start
        wait_osctld_ready
        machine.wait_until_online
      end

      describe 'running container with a missing rootfs dataset', order: :defined do
        before(:context) do
          machine.execute("osctl ct del -f --prune #{Shellwords.escape(ctid)} >/dev/null 2>&1 || true")
          machine.all_succeed(
            "osctl ct new --distribution alpine #{Shellwords.escape(ctid)}",
            "osctl ct unset start-menu #{Shellwords.escape(ctid)}",
            "osctl ct start #{Shellwords.escape(ctid)}"
          )
          wait_ct_running(ctid)
          @dataset = ct_dataset(ctid)
          @lxc_path = ct_info(ctid)['lxc_path']
          @deleted = false
        end

        after(:context) do
          unless @deleted
            machine.execute("zfs rename -u #{Shellwords.escape(@trashed_dataset)} #{Shellwords.escape(@dataset)} >/dev/null 2>&1 || true") if @dataset && @trashed_dataset
            machine.execute("osctl ct del -f --prune #{Shellwords.escape(ctid)} >/dev/null 2>&1 || true")
          end
          machine.execute("lxc-stop -k -P #{Shellwords.escape(@lxc_path)} -n #{Shellwords.escape(ctid)} >/dev/null 2>&1 || true") if @lxc_path
          machine.execute("zfs destroy -r -f #{Shellwords.escape(@dataset)} >/dev/null 2>&1 || true") if @dataset
          machine.execute("zfs destroy -r -f #{Shellwords.escape(@trashed_dataset)} >/dev/null 2>&1 || true") if @trashed_dataset
        end

        it 'starts from a running container' do
          expect(ct_runtime_state(ctid)).to eq('running')
          expect(output_of("zfs list -H -o name #{Shellwords.escape(@dataset)}")).to eq(@dataset)
        end

        it 'keeps osctld operational after the live dataset disappears' do
          @trashed_dataset = trash_dataset(@dataset)

          expect_osctld_operational
        end

        it 'reports a configuration error while the runtime remains running' do
          restart_osctld

          expect_osctld_operational
          info = ct_info(ctid)
          expect(info['config_state']).to eq('error')
          expect(info.dig('config_state_error', 'source')).to eq('lxc_config')
          expect(info['runtime_state']).to eq('running')
          expect(info['runtime_state_error']).to be_nil
        end

        it 'deletes the errored container while its original dataset is absent' do
          machine.succeeds("osctl ct del -f --prune #{Shellwords.escape(ctid)}")
          @deleted = true

          expect(machine.execute("osctl ct show #{Shellwords.escape(ctid)} >/dev/null 2>&1")[0]).not_to eq(0)
          expect_osctld_operational
        end
      end

      describe 'container delete with a stale shared directory', order: :defined do
        delete_ctid = get_container_id('stale-shared-dir')

        before(:context) do
          machine.execute("osctl ct del -f --prune #{Shellwords.escape(delete_ctid)} >/dev/null 2>&1 || true")
          machine.all_succeed(
            "osctl ct new --distribution alpine #{Shellwords.escape(delete_ctid)}",
            "osctl ct unset start-menu #{Shellwords.escape(delete_ctid)}"
          )
        end

        after(:context) do
          machine.execute("osctl ct del -f --prune #{Shellwords.escape(delete_ctid)} >/dev/null 2>&1 || true")
        end

        it 'does not fail on a stale non-mounted child directory' do
          shared_dir = shared_dir_path(delete_ctid)

          machine.succeeds("mkdir -p #{Shellwords.escape(File.join(shared_dir, 'stale'))}")
          expect(machine.execute("mountpoint -q #{Shellwords.escape(shared_dir)}")[0]).not_to eq(0)

          machine.succeeds("osctl ct del -f --prune #{Shellwords.escape(delete_ctid)}")
          expect(machine.execute("test -e #{Shellwords.escape(shared_dir)}")[0]).not_to eq(0)
          expect_osctld_operational
        end
      end
    '';
  }
)
