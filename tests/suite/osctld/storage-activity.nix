import ../../make-test.nix (
  { pkgs }:
  {
    name = "osctld-storage-activity";

    description = ''
      Test the read-only osctld pool storage activity command
    '';

    tags = [ "ci" ];

    machine = import ../../machines/vpsadminos/tank.nix pkgs;

    testScript = ''
      require 'json'

      def self.activity(opts)
        request = JSON.generate(cmd: 'pool_storage_activity', opts:)
        _, output = machine.succeeds(<<~SH)
          ruby -rjson -rsocket <<'RUBY'
            socket = UNIXSocket.new('/run/osctl/osctld.sock')
            socket.gets
            socket.puts(#{request.inspect})
            puts(socket.gets)
          RUBY
        SH

        JSON.parse(output)
      end

      describe 'pool storage activity' do
        before(:suite) do
          machine.start
          machine.wait_for_service('osctld')
          machine.wait_for_osctl_pool('tank')
        end

        it 'returns a bounded v1 sample for the imported pool' do
          response = activity(pool: 'tank')
          expect(response['status']).to be(true)
          sample = response.fetch('response')

          expect(sample.keys).to match_array(%w[
            version coverage daemon_boot_uuid pool_instance_uuid generation
            pool state counts registered_run_datasets worker_alive
            unknown_reasons unknown overflow idle
          ])
          expect(sample).to include(
            'version' => 1, 'coverage' => 'gc_trash_v1', 'pool' => 'tank',
            'state' => 'active'
          )
          expect(sample['daemon_boot_uuid']).to match(/\A[0-9a-f-]{36}\z/)
          expect(sample['pool_instance_uuid']).to match(/\A[0-9a-f-]{36}\z/)
          expect(sample['counts'].keys).to match_array(%w[run_gc trash_prune trash_move])
          sample['counts'].each_value do |counts|
            expect(counts.keys).to match_array(%w[pending running])
            expect(counts.values).to all(be_between(0, 10_000))
          end
          expect(sample['worker_alive'].keys).to match_array(%w[run_gc trash_prune])
          sample['worker_alive'].each_value do |alive|
            expect([true, false]).to include(alive)
          end
          expect([true, false]).to include(sample['unknown'], sample['overflow'], sample['idle'])

          if sample['idle']
            expect(sample['unknown']).to be(false)
            expect(sample['overflow']).to be(false)
            expect(sample['counts'].values.flat_map(&:values)).to all(eq(0))
          end
        end

        it 'advances generation on an enqueued GC run' do
          before = activity(pool: 'tank').fetch('response')
          machine.succeeds('osctl garbage-collector prune tank')
          after = activity(pool: 'tank').fetch('response')

          expect(after['daemon_boot_uuid']).to eq(before['daemon_boot_uuid'])
          expect(after['pool_instance_uuid']).to eq(before['pool_instance_uuid'])
          expect(after['generation']).to be > before['generation']
        end

        it 'treats an absent pool as unknown and rejects extra options' do
          absent = activity(pool: 'not-imported').fetch('response')
          expect(absent).to include(
            'state' => 'absent', 'unknown' => true, 'overflow' => false,
            'idle' => false
          )
          expect(absent['pool_instance_uuid']).to be_nil

          invalid = activity(pool: 'tank', extra: true)
          expect(invalid['status']).to be(false)
          expect(invalid['message']).to include('exactly one zpool')
        end
      end
    '';
  }
)
