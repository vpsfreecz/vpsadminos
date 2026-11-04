# frozen_string_literal: true

# rubocop:disable Lint/UnusedBlockArgument, RSpec/DescribeClass, RSpec/InstanceVariable, RSpec/VerifiedDoubles

require 'stringio'
require 'osctld/exceptions'
require 'osctld/command'
require 'osctld/manipulable'
require 'osctld/db/pools'
require 'osctld/daemon'

module OsCtld
  module Commands
    module Self; end
    module Pool; end
    module User; end
  end
end

require 'osctld/commands/self/shutdown'
require 'osctld/commands/pool/import'
require 'osctld/commands/pool/export'
require 'osctld/commands/user/delete'
require 'osctld/commands/user/subugids'

RSpec.describe 'heavy system commands' do
  def lockable(obj)
    obj.define_singleton_method(:manipulated_by) { @manipulated_by }
    obj.define_singleton_method(:acquire_manipulation_lock) do |holder, block: false|
      @manipulated_by = holder
      true
    end
    obj.define_singleton_method(:release_manipulation_lock) do
      @manipulated_by = nil
    end
    obj
  end

  before do
    allow(OsCtl::Lib::Logger).to receive(:log)
  end

  describe OsCtld::Commands::Self::Shutdown do
    let(:daemon) { double('Daemon', begin_shutdown: nil, abort_shutdown?: false, confirm_shutdown: nil) }

    before do
      daemon_class = stub_const('OsCtld::Daemon', Class.new do
        def self.get; end
      end)
      allow(daemon_class).to receive(:get).and_return(daemon)
      allow(daemon).to receive(:run_shutdown) do |&block|
        daemon.begin_shutdown
        result = block.call
        daemon.confirm_shutdown
        result
      end
      pool_export = stub_const('OsCtld::Commands::Pool::Export', Class.new do
        def self.run(**); end
      end)
      allow(pool_export).to receive(:run).and_return(status: true, output: nil)
    end

    it 'grabs pools and containers, autostops multiple pools, and exports them with the wall message' do
      tracker_class = stub_const('OsCtld::ProgressTracker', Class.new)
      allow(tracker_class).to receive(:new).and_return(double('Tracker'))
      pool1 = lockable(
        Struct.new(:name) do
          attr_reader :disabled, :begin_stop_calls, :autostop_calls, :wait_calls

          def initialize(*)
            super
            @disabled = false
            @begin_stop_calls = 0
            @autostop_calls = []
            @wait_calls = 0
          end

          def exclusively
            yield
          end

          def disable
            @disabled = true
          end

          def begin_stop
            @begin_stop_calls += 1
          end

          def autostop_no_wait(**opts)
            @autostop_calls << opts
          end

          def wait_for_autostop
            @wait_calls += 1
          end
        end.new('tank')
      )
      pool2 = lockable(
        Struct.new(:name) do
          attr_reader :disabled, :begin_stop_calls, :autostop_calls, :wait_calls

          def initialize(*)
            super
            @disabled = false
            @begin_stop_calls = 0
            @autostop_calls = []
            @wait_calls = 0
          end

          def exclusively
            yield
          end

          def disable
            @disabled = true
          end

          def begin_stop
            @begin_stop_calls += 1
          end

          def autostop_no_wait(**opts)
            @autostop_calls << opts
          end

          def wait_for_autostop
            @wait_calls += 1
          end
        end.new('pool2')
      )
      ct1 = lockable(Struct.new(:pool).new(pool1))
      ct2 = lockable(Struct.new(:pool).new(pool2))
      db_pools = stub_const('OsCtld::DB::Pools', Class.new do
        def self.get; end
      end)
      db_cts = stub_const('OsCtld::DB::Containers', Class.new do
        def self.get; end
      end)
      allow(db_pools).to receive(:get) { [pool1, pool2] }
      allow(db_cts).to receive(:get) { [ct1, ct2] }

      expect(
        described_class.run(wall: true, message: 'Shutting down')
      ).to eq(status: true, output: nil)
      expect(daemon).to have_received(:begin_shutdown)
      expect(daemon).to have_received(:confirm_shutdown)
      expect(pool1.autostop_calls.first[:message]).to eq('Shutting down')
      expect(pool2.autostop_calls.first[:message]).to eq('Shutting down')
      expect(OsCtld::Commands::Pool::Export).to have_received(:run).with(
        internal: { handler: nil, indirect: true },
        name: 'tank',
        force: true,
        grab_containers: false,
        stop_containers: true,
        unregister_users: false,
        message: 'Shutting down'
      )
      expect(OsCtld::Commands::Pool::Export).to have_received(:run).with(
        internal: { handler: nil, indirect: true },
        name: 'pool2',
        force: true,
        grab_containers: false,
        stop_containers: true,
        unregister_users: false,
        message: 'Shutting down'
      )
    end

    it 'releases already grabbed pools when shutdown is aborted early' do
      pool = lockable(Struct.new(:name) do
        def exclusively
          yield
        end
      end.new('tank'))
      db_pools = stub_const('OsCtld::DB::Pools', Class.new do
        def self.get; end
      end)
      db_cts = stub_const('OsCtld::DB::Containers', Class.new do
        def self.get; end
      end)
      allow(db_pools).to receive(:get).and_return([pool])
      allow(db_cts).to receive(:get).and_return([])
      allow(daemon).to receive(:abort_shutdown?).and_return(false, true)

      expect { described_class.run }
        .to raise_error(OsCtld::CommandFailed, 'shutdown aborted')
      expect(pool.manipulated_by).to be_nil
    end
  end

  describe 'shutdown with real pool manipulation locks' do
    let(:daemon) do
      OsCtld::Daemon.allocate.tap do |d|
        d.instance_variable_set(:@shutdown_mutex, Mutex.new)
        d.instance_variable_set(:@shutdown_cv, ConditionVariable.new)
      end
    end
    let(:pool) { OsCtld::Pool.new('tank') }

    def shutdown_gate
      Queue.new.tap { |q| @shutdown_gates << q }
    end

    def start_shutdown(command, keep_alive: false)
      result = Queue.new
      alive = shutdown_gate if keep_alive
      thread = Thread.new do
        result << command.base_execute
      rescue Exception => e # rubocop:disable Lint/RescueException -- Preserve interruption and cleanup outcomes.
        result << e
      ensure
        pop_with_timeout(alive, timeout: 5) if alive
      end
      @shutdown_threads << thread
      [result, thread]
    end

    before do
      @shutdown_gates = []
      @shutdown_threads = []
      @joined = Queue.new
      @marker_dir = Dir.mktmpdir('osctld-shutdown-spec-')
      stub_const('OsCtld::RunState::SHUTDOWN_MARKER', File.join(@marker_dir, 'shutdown'))
      # osctld runs as root and can reopen its mode-000 marker. Emulate only
      # that privilege for this temporary fixture, preserving the mode tested.
      allow(File).to receive(:new).and_wrap_original do |method, path, *args|
        if path == OsCtld::RunState::SHUTDOWN_MARKER && File.exist?(path)
          mode = File.stat(path).mode & 0o777
          File.chmod(mode | 0o200, path)
        end
        begin
          method.call(path, *args)
        ensure
          File.chmod(mode, path) if mode
        end
      end
      # External work is inert; locks, snapshots, nested export and removal are real.
      stub_const('OsCtld::Pool', Class.new do
        include OsCtld::Manipulable

        attr_reader :name

        def initialize(name)
          @name = name
          init_manipulable
        end

        def id = name
        def pool = self
        def manipulation_resource = ['pool', name]
        def exclusively = yield
        def disable; end
        def begin_export; end
        def begin_stop; end
        def autostop_and_wait(**); end
        def all_stop; end
        def abort_export? = false
      end)
      stub_const('OsCtld::DB::Pools', Class.new(OsCtld::DB::List))
      %w[Containers Users Groups Repositories IdRanges].each do |name|
        registry = stub_const("OsCtld::DB::#{name}", Class.new do
          def self.get = []
        end)
        registry.define_singleton_method(:root) { |_pool| nil } if name == 'Groups'
      end
      stub_const('OsCtld::Hook', Class.new do
        def self.run(*); end
      end)
      stub_const('OsCtld::History', Class.new do
        def self.close(*); end
      end)
      stub_const('OsCtld::SendReceive', Module.new do
        def self.deploy; end
      end)
      stub_const('OsCtld::Eventd', Module.new do
        def self.report(*); end
      end)
      allow(OsCtld::Daemon).to receive(:get).and_return(daemon)
      allow(daemon.instance_variable_get(:@shutdown_cv)).to receive(:wait).and_wrap_original do |method, mutex|
        @joined << Thread.current
        method.call(mutex)
      end
      allow(OsCtld::Commands::Pool::Export).to receive(:run).and_call_original
      OsCtld::DB::Pools.add(pool)
    end

    after do
      daemon.abort_shutdown if @shutdown_threads.any?(&:alive?)
      @shutdown_gates.each { |gate| gate << :release }
      joined = @shutdown_threads.map { |thread| !thread.join(5).nil? }
      FileUtils.remove_entry(@marker_dir)
      raise 'shutdown fixture left a thread alive' unless joined.all?
    end

    it 'completes a single shutdown and releases the nested export outer hold' do
      command = OsCtld::Commands::Self::Shutdown.new({}, id: 101)
      expect(command.base_execute).to eq(status: true, output: nil)
      expect(OsCtld::DB::Pools.get).to be_empty
      expect(OsCtld::Commands::Pool::Export).to have_received(:run).once
      expect(pool.manipulated_by).to be_nil
      expect(File.stat(OsCtld::RunState::SHUTDOWN_MARKER).mode & 0o777).to eq(0o100)
    end

    [['setup', 'client'], ['client', 'setup'], ['client', 'duplicate client']].each do |owner_kind, joiner_kind|
      it "joins #{joiner_kind} to #{owner_kind} before snapshots and through both export tails" do
        owner = OsCtld::Commands::Self::Shutdown.new({ cli: owner_kind }, id: 201)
        joiner = OsCtld::Commands::Self::Shutdown.new({ cli: joiner_kind }, id: 202)
        import_holder = Struct.new(:manipulation_holder).new('pool_import')
        retry_entered = Queue.new
        resume_owner = shutdown_gate
        tail_entered = Queue.new
        deploy_gate = shutdown_gate
        hook_gate = shutdown_gate
        snapshot_threads = []
        allow(OsCtld::DB::Pools).to receive(:get).and_wrap_original do |method, *args|
          snapshot_threads << Thread.current
          method.call(*args)
        end
        allow(owner).to receive(:sleep) do |_seconds|
          retry_entered << pool.manipulated_by
          pop_with_timeout(resume_owner, timeout: 5)
        end
        allow(OsCtld::SendReceive).to receive(:deploy) do
          tail_entered << :deploy
          pop_with_timeout(deploy_gate, timeout: 5)
        end
        allow(OsCtld::Hook).to receive(:run) do |_pool, event|
          next unless event == :post_export

          tail_entered << :post_export
          pop_with_timeout(hook_gate, timeout: 5)
        end

        pool.acquire_manipulation_lock(import_holder)
        begin
          owner_result, owner_thread = start_shutdown(owner, keep_alive: true)
          expect(pop_with_timeout(retry_entered, timeout: 5)).to equal(import_holder)
          joiner_result, joiner_thread = start_shutdown(joiner)
          expect(pop_with_timeout(@joined, timeout: 5)).to equal(joiner_thread)
          expect(snapshot_threads).not_to include(joiner_thread)
          expect(OsCtld::Commands::Pool::Export).not_to have_received(:run)
        ensure
          pool.release_manipulation_lock if pool.manipulated_by.equal?(import_holder)
        end
        resume_owner << :retry
        expect(pop_with_timeout(tail_entered, timeout: 5)).to eq(:deploy)
        expect(OsCtld::DB::Pools.get).to be_empty
        expect(owner_result).to be_empty
        expect(joiner_result).to be_empty
        expect(File.stat(OsCtld::RunState::SHUTDOWN_MARKER).mode & 0o777).to eq(0)
        deploy_gate << :continue
        expect(pop_with_timeout(tail_entered, timeout: 5)).to eq(:post_export)
        expect(joiner_result).to be_empty
        expect(File.stat(OsCtld::RunState::SHUTDOWN_MARKER).mode & 0o777).to eq(0)
        hook_gate << :continue
        result = pop_with_timeout(owner_result, timeout: 5)
        expect(result).to eq(status: true, output: nil)
        expect(pop_with_timeout(joiner_result, timeout: 5)).to equal(result)
        expect(owner_thread).to be_alive
        expect(pool.manipulated_by).to be_nil
        expect(snapshot_threads).not_to include(joiner_thread)
        expect(OsCtld::Commands::Pool::Export).to have_received(:run).once
      end
    end

    %i[deploy post_export].each do |failure_at|
      it "shares a #{failure_at} failure after removal and leaves pending restart intent" do
        entered = Queue.new
        release = shutdown_gate
        error = RuntimeError.new('export tail fixture failure')
        if failure_at == :deploy
          allow(OsCtld::SendReceive).to receive(:deploy) do
            entered << :tail
            pop_with_timeout(release, timeout: 5)
            raise error
          end
        else
          allow(OsCtld::Hook).to receive(:run) do |_pool, event|
            next unless event == :post_export

            entered << :tail
            pop_with_timeout(release, timeout: 5)
            raise error
          end
        end
        owner_result, owner_thread = start_shutdown(OsCtld::Commands::Self::Shutdown.new({}, id: 301), keep_alive: true)
        pop_with_timeout(entered, timeout: 5)
        joiner_result, = start_shutdown(OsCtld::Commands::Self::Shutdown.new({}, id: 302))
        pop_with_timeout(@joined, timeout: 5)
        expect(OsCtld::DB::Pools.get).to be_empty
        expect(joiner_result).to be_empty
        release << :continue
        expect(pop_with_timeout(owner_result, timeout: 5)).to equal(error)
        expect(pop_with_timeout(joiner_result, timeout: 5)).to equal(error)
        expect(owner_thread).to be_alive
        expect(pool.manipulated_by).to be_nil
        expect(File.stat(OsCtld::RunState::SHUTDOWN_MARKER).mode & 0o777).to eq(0)
        # A genuinely later request sees the live, empty DB and may finish.
        expect(OsCtld::Commands::Self::Shutdown.run).to eq(status: true, output: nil)
      end
    end

    [false, true].each do |partial|
      it "shares abort while waiting for import with partial acquisition #{partial}" do
        blocked = partial ? OsCtld::Pool.new('importing') : pool
        OsCtld::DB::Pools.add(blocked) if partial
        holder = Struct.new(:manipulation_holder).new('pool_import')
        retry_entered = Queue.new
        resume = shutdown_gate
        owner = OsCtld::Commands::Self::Shutdown.new({}, id: 401)
        allow(owner).to receive(:sleep) do |_seconds|
          retry_entered << :retry
          pop_with_timeout(resume, timeout: 5)
        end
        blocked.acquire_manipulation_lock(holder)
        begin
          owner_result, = start_shutdown(owner)
          pop_with_timeout(retry_entered, timeout: 5)
          joiner_result, = start_shutdown(OsCtld::Commands::Self::Shutdown.new({}, id: 402))
          pop_with_timeout(@joined, timeout: 5)
          expect(pool.manipulated_by).to equal(owner) if partial
          daemon.abort_shutdown
          expect(daemon.shutdown?).to be(false)
          late_result, = start_shutdown(OsCtld::Commands::Self::Shutdown.new({}, id: 403))
          pop_with_timeout(@joined, timeout: 5)
          expect(daemon.abort_shutdown?).to be(true)
          expect(daemon.shutdown?).to be(false)
          resume << :abort
          error = pop_with_timeout(owner_result, timeout: 5)
          expect(error).to be_a(OsCtld::CommandFailed)
          expect(error.message).to eq('shutdown aborted')
          expect(pop_with_timeout(joiner_result, timeout: 5)).to equal(error)
          expect(pop_with_timeout(late_result, timeout: 5)).to equal(error)
          expect(blocked.manipulated_by).to equal(holder)
          expect(pool.manipulated_by).to be_nil if partial
          expect(daemon.shutdown?).to be(false)
        ensure
          blocked.release_manipulation_lock if blocked.manipulated_by.equal?(holder)
        end
      end
    end

    it 'rejects confirmation when abort arrives during the final post-export hook' do
      entered = Queue.new
      release = shutdown_gate
      allow(OsCtld::Hook).to receive(:run) do |_pool, event|
        next unless event == :post_export

        entered << :tail
        pop_with_timeout(release, timeout: 5)
      end
      owner_result, = start_shutdown(OsCtld::Commands::Self::Shutdown.new({}, id: 501))
      pop_with_timeout(entered, timeout: 5)
      joiner_result, = start_shutdown(OsCtld::Commands::Self::Shutdown.new({}, id: 502))
      pop_with_timeout(@joined, timeout: 5)
      daemon.abort_shutdown
      expect(daemon.shutdown?).to be(false)
      # The unchanged CLI writes restart intent before sending a request.
      File.new(OsCtld::RunState::SHUTDOWN_MARKER, 'w', 0o000).close
      release << :continue
      error = pop_with_timeout(owner_result, timeout: 5)
      expect(error).to be_a(OsCtld::CommandFailed)
      expect(pop_with_timeout(joiner_result, timeout: 5)).to equal(error)
      expect(pool.manipulated_by).to be_nil
      expect(daemon.shutdown?).to be(false)
      expect(OsCtld::Commands::Self::Shutdown.run).to eq(status: true, output: nil)
    end

    %i[pool container].each do |kind|
      it "releases partial #{kind} acquisition when the next acquisition raises" do
        error = RuntimeError.new('acquisition fixture failure')
        second = OsCtld::Pool.new('second')
        first = kind == :pool ? pool : OsCtld::Pool.new('first_container')
        if kind == :pool
          OsCtld::DB::Pools.add(second)
        else
          allow(OsCtld::DB::Containers).to receive(:get).and_return([first, second])
        end
        allow(second).to receive(:acquire_manipulation_lock).and_raise(error)
        expect { OsCtld::Commands::Self::Shutdown.run }.to(raise_error { |e| expect(e).to equal(error) })
        expect(pool.manipulated_by).to be_nil
        expect(first.manipulated_by).to be_nil
        expect(second.manipulated_by).to be_nil
        expect(File.stat(OsCtld::RunState::SHUTDOWN_MARKER).mode & 0o777).to eq(0)
      end
    end

    [false, true].each do |foreign_hold|
      it "skips a container lock already released or transferred, foreign hold #{foreign_hold}" do
        ct = OsCtld::Pool.new('container')
        allow(OsCtld::DB::Containers).to receive(:get).and_return([ct])
        transfer = shutdown_gate
        acquired = Queue.new
        release = shutdown_gate
        foreign = Object.new
        if foreign_hold
          @shutdown_threads << Thread.new do
            pop_with_timeout(transfer, timeout: 5)
            ct.acquire_manipulation_lock(foreign)
            acquired << :held
            begin
              pop_with_timeout(release, timeout: 5)
            ensure
              ct.release_manipulation_lock
            end
          end
        end
        error = RuntimeError.new('export fixture failure')
        allow(pool).to receive(:begin_export) do
          ct.release_manipulation_lock
          if foreign_hold
            transfer << :transfer
            pop_with_timeout(acquired, timeout: 5)
          end
          raise error
        end
        expect { OsCtld::Commands::Self::Shutdown.run }.to(raise_error { |e| expect(e).to equal(error) })
        expect(pool.manipulated_by).to be_nil
        expect(ct.manipulated_by).to equal(foreign_hold ? foreign : nil)
      end
    end

    [false, true].each do |primary_failure|
      it "finishes all cleanup and preserves the original error, primary failure #{primary_failure}" do
        original = RuntimeError.new('export fixture failure')
        cleanup = RuntimeError.new('cleanup fixture failure')
        allow(OsCtld::SendReceive).to receive(:deploy).and_raise(original) if primary_failure
        allow(pool).to receive(:release_manipulation_lock).and_wrap_original do |method|
          method.call
          raise cleanup
        end
        expect { OsCtld::Commands::Self::Shutdown.run }
          .to(raise_error { |e| expect(e).to equal(primary_failure ? original : cleanup) })
        expect(pool.manipulated_by).to be_nil
        expect(File.stat(OsCtld::RunState::SHUTDOWN_MARKER).mode & 0o777).to eq(0)
      end
    end
  end

  describe OsCtld::Commands::Pool::Import do
    before do
      stub_const('OsCtld::Pool', Class.new do
        attr_reader :name, :dataset

        def initialize(name, dataset)
          @name = name
          @dataset = dataset
        end

        def manipulate(_holder, block:, &)
          yield
        end

        def init; end
        def setup; end
        def disable; end
        def autostart; end
      end)
      stub_const('OsCtld::Pool::PROPERTY_ACTIVE', 'org.vpsadminos.active')
      stub_const('OsCtld::Pool::PROPERTY_DATASET', 'org.vpsadminos.dataset')
      hook = stub_const('OsCtld::Hook', Class.new do
        def self.run(*); end
      end)
      daemon_class = stub_const('OsCtld::Daemon', Class.new do
        def self.get; end
      end)
      allow(hook).to receive(:run)
      allow(daemon_class).to receive(:get).and_return(double(shutdown?: false))
      db_pools = stub_const('OsCtld::DB::Pools', Class.new do
        def self.contains?(_name); end

        def self.sync(&block)
          block.call
        end

        def self.add(_pool); end

        def self.remove(_pool); end
      end)
      allow(db_pools).to receive(:contains?).and_return(false)
      allow(db_pools).to receive(:add)
      allow(db_pools).to receive(:remove)
    end

    it 'rejects importing a pool that is not mounted' do
      db_pools = OsCtld::DB::Pools
      allow(db_pools).to receive(:contains?).with('tank').and_return(false)
      command = described_class.new({ name: 'tank' }, {})
      allow(command).to receive(:zfs).with(
        :get,
        '-H -o value mounted,org.vpsadminos.dataset',
        'tank'
      ).and_return(double(output: "no -\n"))

      expect { command.execute }
        .to raise_error(OsCtld::CommandFailed, 'the pool is not mounted')
    end

    it 'removes the pool from the database when an upgrade fails during import' do
      command = described_class.new({}, {})
      allow(command).to receive(:upgrade).with('tank') do
        raise OsCtld::PoolUpgradeError.new('tank', StandardError.new('boom'))
      end

      expect { command.send(:do_import, 'tank', 'tank/data') }
        .to raise_error(OsCtld::PoolUpgradeError)
      expect(OsCtld::DB::Pools).to have_received(:remove).with(instance_of(OsCtld::Pool))
    end
  end

  describe OsCtld::Commands::Pool::Export do
    before do
      hook = stub_const('OsCtld::Hook', Class.new do
        def self.run(*); end
      end)
      allow(hook).to receive(:run)
      stub_const('OsCtld::User', Class.new do
        attr_accessor :pool, :name, :userdir, :id_range_allocation_owner

        def exclusively
          yield
        end
      end)
      stub_const('OsCtld::Container', Class.new do
        attr_accessor :pool, :ident, :state

        def unregister; end
      end)
      stub_const('OsCtld::Repository', Class.new do
        attr_accessor :pool

        def stop; end
      end)
      daemon_class = stub_const('OsCtld::Daemon', Class.new do
        def self.get; end
      end)
      allow(daemon_class).to receive(:get).and_return(double(shutdown?: false, abort_shutdown?: false))
    end

    it 'returns ok with a progress note when the pool is missing and if_imported is set' do
      db_pools = stub_const('OsCtld::DB::Pools', Class.new do
        def self.find(_name); end
      end)
      allow(db_pools).to receive(:find).with('tank').and_return(nil)
      command = described_class.new({ name: 'tank', if_imported: true }, {})
      allow(command).to receive(:progress)

      expect(command.execute).to eq(status: true, output: nil)
      expect(command).to have_received(:progress).with('pool not imported')
    end

    it 'rejects exports of pools with running containers unless forced' do
      pool = double('Pool')
      db_pools = stub_const('OsCtld::DB::Pools', Class.new do
        def self.find(_name); end
      end)
      db_cts = stub_const('OsCtld::DB::Containers', Class.new do
        def self.get; end
      end)
      allow(db_pools).to receive(:find).with('tank').and_return(pool)
      allow(db_cts).to receive(:get).and_return([Struct.new(:pool) do
        def running?
          true
        end
      end.new(pool)])

      expect { described_class.run(name: 'tank') }
        .to raise_error(OsCtld::CommandFailed, 'the pool has running containers')
    end

    it 'unregisters entities, regenerates user files, removes the pool, and deploys send-receive keys' do
      user_unreg = stub_const('OsCtld::Commands::User::Unregister', Class.new)
      subugids = stub_const('OsCtld::Commands::User::SubUGIds', Class.new)
      usernet = stub_const('OsCtld::Commands::User::LxcUsernet', Class.new)
      monitor = stub_const('OsCtld::Monitor::Master', Class.new do
        def self.demonitor(*); end
      end)
      console = stub_const('OsCtld::Console', Class.new do
        def self.remove(*); end
      end)
      history = stub_const('OsCtld::History', Class.new do
        def self.close(*); end
      end)
      send_receive = stub_const('OsCtld::SendReceive', Class.new do
        def self.deploy; end
      end)
      bpf = stub_const('OsCtld::BpfFs', Class.new do
        def self.remove_pool(*); end
      end)
      cgroup = stub_const('OsCtld::CGroup', Class.new do
        def self.rmpath_all(*); end
      end)
      allow(monitor).to receive(:demonitor)
      allow(console).to receive(:remove)
      allow(history).to receive(:close)
      allow(send_receive).to receive(:deploy)
      allow(bpf).to receive(:remove_pool)
      allow(cgroup).to receive(:rmpath_all)

      pool = lockable(
        Struct.new(:name) do
          def manipulate(_holder, block:, &)
            yield
          end

          def begin_export; end
          def begin_stop; end

          def exclusively
            yield
          end

          def disable; end
          def autostop_and_wait(**); end
          def all_stop; end
          def abort_export? = false
        end.new('tank')
      )
      root_group = Struct.new(:pool, :cgroup_path).new(pool, '/sys/fs/cgroup/osctl/root')
      user_class = OsCtld::User
      container_class = OsCtld::Container
      repo_class = OsCtld::Repository
      user = lockable(user_class.new).tap do |u|
        u.pool = pool
        u.name = 'alice'
        u.userdir = '/home/alice'
        u.id_range_allocation_owner = 'user:alice'
      end
      ct = lockable(container_class.new).tap do |c|
        c.pool = pool
        c.ident = 'tank:ct1'
        c.state = :stopped
      end
      repo = repo_class.new.tap do |r|
        r.pool = pool
      end
      id_range = Struct.new(:pool) do
        def free_by(_owner); end
      end.new(pool)
      db_pools = stub_const('OsCtld::DB::Pools', Class.new do
        def self.find(_name); end
        def self.remove(_pool); end
      end)
      db_cts = stub_const('OsCtld::DB::Containers', Class.new do
        def self.get; end
        def self.remove(_obj); end
      end)
      db_users = stub_const('OsCtld::DB::Users', Class.new do
        def self.get; end
        def self.remove(_obj); end
      end)
      db_groups = stub_const('OsCtld::DB::Groups', Class.new do
        def self.get; end
        def self.remove(_obj); end
        def self.root(_pool); end
      end)
      db_repos = stub_const('OsCtld::DB::Repositories', Class.new do
        def self.get; end
        def self.remove(_obj); end
      end)
      db_ranges = stub_const('OsCtld::DB::IdRanges', Class.new do
        def self.get; end
        def self.remove(_obj); end
      end)
      supervisor = stub_const('OsCtld::UserControl::Supervisor', Class.new do
        def self.stop_server(*); end
      end)
      allow(db_pools).to receive(:find).with('tank').and_return(pool)
      allow(db_cts).to receive(:get).and_return([ct])
      allow(db_users).to receive(:get).and_return([user])
      allow(db_groups).to receive(:get).and_return([root_group])
      allow(db_groups).to receive(:root).with(pool).and_return(root_group)
      allow(db_repos).to receive(:get).and_return([repo])
      allow(db_ranges).to receive(:get).and_return([id_range])
      allow(db_pools).to receive(:remove).with(pool)
      allow(supervisor).to receive(:stop_server).with(user)

      command = described_class.new(
        {
          name: 'tank',
          force: true,
          stop_containers: true,
          unregister_users: true
        },
        {}
      )
      allow(command).to receive(:call_cmd!).with(
        user_unreg,
        pool: 'tank',
        name: 'alice'
      ).and_return(status: true, output: nil)
      allow(command).to receive(:call_cmd!).with(subugids).and_return(status: true, output: nil)
      allow(command).to receive(:call_cmd!).with(usernet).and_return(status: true, output: nil)
      allow(command).to receive(:syscmd)

      expect(command.execute).to eq(status: true, output: nil)
      expect(monitor).to have_received(:demonitor).with(ct)
      expect(console).to have_received(:remove).with(ct)
      expect(history).to have_received(:close).with(pool)
      expect(send_receive).to have_received(:deploy)
      expect(db_pools).to have_received(:remove).with(pool)
    end
  end

  describe OsCtld::Commands::User::Delete do
    before do
      stub_const('OsCtld::UserControl::Supervisor', Class.new do
        def self.stop_server(*); end
      end)
      stub_const('OsCtld::DB::IdRanges', Class.new do
        def self.get; end
      end)
      stub_const('OsCtld::DB::Users', Class.new do
        def self.remove(_user); end
      end)
      allow(OsCtld::UserControl::Supervisor).to receive(:stop_server)
      allow(OsCtld::DB::Users).to receive(:remove)
    end

    it 'rejects deleting users that still have containers' do
      user = Struct.new do
        def has_containers?
          true
        end
      end.new

      expect { described_class.new({}, {}).execute(user) }
        .to raise_error(OsCtld::CommandFailed, 'user has container(s)')
    end

    it 'unregisters the user, frees id ranges, removes the user, and regenerates subuids' do
      unregister = stub_const('OsCtld::Commands::User::Unregister', Class.new)
      subugids = stub_const('OsCtld::Commands::User::SubUGIds', Class.new)
      ranges = [Struct.new(:pool) do
        attr_reader :freed

        def free_by(owner)
          @freed = owner
        end
      end.new(Struct.new(:name).new('tank'))]
      allow(OsCtld::DB::IdRanges).to receive(:get).and_return(ranges)
      user = lockable(
        Struct.new(:name, :pool, :userdir, :config_path) do
          def has_containers?
            false
          end

          def id_range_allocation_owner
            'user:alice'
          end

          def manipulate(_holder, block:, &)
            yield
          end
        end.new('alice', ranges.first.pool, '/home/alice', '/home/alice.yml')
      )
      command = described_class.new({}, {})
      allow(command).to receive(:call_cmd!).with(
        unregister,
        name: 'alice',
        pool: 'tank'
      ).and_return(status: true, output: nil)
      allow(command).to receive(:call_cmd).with(subugids).and_return(status: true, output: nil)
      allow(command).to receive(:syscmd)
      allow(File).to receive(:unlink).with('/home/alice.yml')

      expect(command.execute(user)).to eq(status: true, output: nil)
      expect(ranges.first.freed).to eq('user:alice')
      expect(OsCtld::DB::Users).to have_received(:remove).with(user)
    end
  end

  describe OsCtld::Commands::User::SubUGIds do
    it 'writes subuid and subgid files from the current user maps' do
      db_users = stub_const('OsCtld::DB::Users', Class.new do
        def self.get; end
      end)
      user = Struct.new(:ugid, :uid_map, :gid_map).new(
        1000,
        [Struct.new(:host_id, :id_count).new(100_000, 65_536)],
        [Struct.new(:host_id, :id_count).new(200_000, 65_536)]
      )
      allow(db_users).to receive(:get).and_yield([user])
      open_buffers = {}
      allow(File).to receive(:open) do |path, _mode, &block|
        io = StringIO.new
        open_buffers[path] = io
        block.call(io)
      end
      renames = []
      allow(File).to receive(:rename) do |src, dst|
        renames << [src, dst]
      end

      expect(described_class.run).to eq(status: true, output: nil)
      expect(open_buffers['/etc/subuid.new'].string).to eq("1000:100000:65536\n")
      expect(open_buffers['/etc/subgid.new'].string).to eq("1000:200000:65536\n")
      expect(renames).to eq(
        [
          ['/etc/subuid.new', '/etc/subuid'],
          ['/etc/subgid.new', '/etc/subgid']
        ]
      )
    end
  end
end

# rubocop:enable Lint/UnusedBlockArgument, RSpec/DescribeClass, RSpec/InstanceVariable, RSpec/VerifiedDoubles
