# frozen_string_literal: true

# rubocop:disable Lint/ConstantDefinitionInBlock, Lint/StructNewOverride, RSpec/DescribeClass, RSpec/LeakyConstantDeclaration, RSpec/VerifiedDoubles

require 'fileutils'
require 'ostruct'
require 'osctld/exceptions'
require 'osctld/command'
require 'osctld/container_control/command'
require 'osctld/switch_user'
require 'osctld/utils/container'
require 'osctld/utils/switch_user'
require 'osctld/commands/container/start'
require 'osctld/commands/container/stop'
require 'osctld/commands/container/restart'
require 'osctld/commands/container/boot'
require 'osctld/commands/container/delete'
require 'osctld/commands/container/freeze'
require 'osctld/commands/container/unfreeze'
require 'osctld/commands/container/reconfigure'

RSpec.describe 'container lifecycle commands' do
  Event = Struct.new(:type, :opts, keyword_init: true)

  def build_history
    stub_const('OsCtld::History', Class.new do
      def self.log(*); end
    end)
  end

  def build_db_containers
    stub_const('OsCtld::DB::Containers', Class.new do
      def self.find(_id, _pool); end

      def self.remove(_ct); end
    end)
  end

  before do
    allow(OsCtl::Lib::Logger).to receive(:log)
    allow(build_history).to receive(:log)
  end

  describe OsCtld::Commands::Container::Start do
    let(:autostart_plan) do
      Class.new do
        attr_reader :enqueue_calls, :start_calls

        def initialize
          @enqueue_calls = []
          @start_calls = []
        end

        def enqueue(ct, **opts)
          enqueue_calls << [ct, opts]
        end

        def start_ct(ct, **opts)
          start_calls << [ct, opts]
          :queued
        end
      end.new
    end

    let(:pool) do
      Struct.new(:name, :console_dir, :autostart_plan).new('tank', '/tmp/console', autostart_plan)
    end

    let(:ct) { Struct.new(:id, :pool).new('ct1', pool) }

    it 'enqueues queued starts when waiting is disabled' do
      command = described_class.new({ queue: true, wait: false, priority: 10 }, {})

      expect(command.send(:start_queued, ct)).to eq(status: true, output: nil)
      expect(autostart_plan.enqueue_calls).to eq(
        [[ct, { priority: 10, start_opts: command.opts }]]
      )
    end

    it 'returns the timeout-style response when the queued start times out' do
      allow(autostart_plan).to receive(:start_ct).and_return(nil)
      command = described_class.new({ queue: true, wait: 5, priority: 20 }, {})

      expect(command.send(:start_queued, ct)).to eq(status: true, output: 'Timed out')
      expect(autostart_plan).to have_received(:start_ct).with(
        ct,
        priority: 20,
        start_opts: command.opts,
        client_handler: nil
      )
    end

    it 'rejects starts when the container cannot start' do
      container = Struct.new(:can_start?, :state).new(false, :stopped)
      command = described_class.new({}, {})

      expect { command.send(:start_now, container) }
        .to raise_error(OsCtld::CommandFailed, 'start not available')
    end

    it 'returns ok when the container is already running and force is not set' do
      container = Struct.new(:can_start?, :state).new(true, :running)
      command = described_class.new({}, {})

      expect(command.send(:start_now, container)).to eq(status: true, output: nil)
    end

    it 'maps dataset mount failures to command errors' do
      run_conf = Struct.new(:mount).new(nil)
      allow(run_conf).to receive(:mount)
        .and_raise(OsCtld::SystemCommandFailed.new('mount', 1, 'no dataset'))
      mounts = Struct.new(:prune).new(nil)
      allow(mounts).to receive(:prune)
      container = Struct.new(
        :can_start?,
        :state,
        :run_conf,
        :impermanence,
        :distribution,
        :mounts,
        keyword_init: true
      ) do
        def init_run_conf; end
      end.new(
        can_start?: true,
        state: :stopped,
        run_conf:,
        impermanence: false,
        distribution: 'almalinux',
        mounts:
      )
      command = described_class.new({}, {})
      allow(command).to receive(:remove_accounting_cgroups)

      expect(command.send(:start_now, container)).to eq(
        status: false,
        message: "failed to mount dataset: command 'mount' exited with code '1', output: 'no dataset'"
      )
    end

    it 'waits through the expected state sequence and ignores unrelated events' do
      queue = Struct.new(:events) do
        def pop(timeout:)
          events.shift
        end
      end.new(
        [
          Event.new(type: :state, opts: { pool: 'other', id: 'ct1', state: :running }),
          Event.new(type: :state, opts: { pool: 'tank', id: 'ct1', state: :stopping }),
          Event.new(type: :state, opts: { pool: 'tank', id: 'ct1', state: :stopped }),
          Event.new(type: :state, opts: { pool: 'tank', id: 'ct1', state: :starting }),
          Event.new(type: :state, opts: { pool: 'tank', id: 'ct1', state: :running })
        ]
      )
      daemon = stub_const('OsCtld::Daemon', Class.new do
        def self.get; end
      end)
      allow(daemon).to receive(:get).and_return(double(stopping?: false))
      command = described_class.new({ wait: 5 }, {})
      allow(command).to receive(:log)

      expect(command.send(:wait_for_ct, queue, ct)).to eq(%i[running])
    end

    it 'returns timeout when no relevant events arrive in time' do
      queue = Struct.new do
        def pop(timeout:)
          nil
        end
      end.new
      daemon = stub_const('OsCtld::Daemon', Class.new do
        def self.get; end
      end)
      allow(daemon).to receive(:get).and_return(double(stopping?: false))
      command = described_class.new({ wait: 1 }, {})
      allow(command).to receive(:log)
      now = Time.now
      allow(Time).to receive(:now).and_return(now, now, now + 2)

      expect(command.send(:wait_for_ct, queue, ct)).to eq(%i[timeout])
    end

    it 'fails when state recovery reports the container stopped' do
      queue = Struct.new(:events) do
        def pop(timeout:)
          events.shift
        end
      end.new(
        [Event.new(type: :state_recovery, opts: { pool: 'tank', id: 'ct1', state: :stopped })]
      )
      daemon = stub_const('OsCtld::Daemon', Class.new do
        def self.get; end
      end)
      allow(daemon).to receive(:get).and_return(double(stopping?: false))
      command = described_class.new({ wait: 5 }, {})
      allow(command).to receive(:log)

      expect(command.send(:wait_for_ct, queue, ct)).to eq(
        [:error, 'start failed, container is found to be stopped']
      )
    end

    it 'fails when osctld is shutting down while waiting' do
      queue = Struct.new(:events) do
        def pop(timeout:)
          events.shift
        end
      end.new([Event.new(type: :osctld_shutdown, opts: {})])
      daemon = stub_const('OsCtld::Daemon', Class.new do
        def self.get; end
      end)
      allow(daemon).to receive(:get).and_return(double(stopping?: false))
      command = described_class.new({ wait: 5 }, {})
      allow(command).to receive(:log)

      expect(command.send(:wait_for_ct, queue, ct)).to eq(
        [:error, 'osctld is shutting down']
      )
    end

    it 'bounds shutdown waiting even when unrelated events keep arriving' do
      queue = Struct.new(:calls) do
        def pop(timeout:)
          self.calls += 1
          Event.new(type: :state, opts: { pool: 'other', id: 'ct1', state: :running })
        end
      end.new(0)
      daemon = stub_const('OsCtld::Daemon', Class.new do
        def self.get; end
      end)
      now = Time.now

      allow(daemon).to receive(:get).and_return(double(stopping?: true))
      allow(Time).to receive(:now).and_return(now, now, now, now + 16)
      command = described_class.new({ wait: 'infinity' }, {})
      allow(command).to receive(:log)

      expect(command.send(:wait_for_ct, queue, ct)).to eq(
        [:error, 'osctld is shutting down']
      )
      expect(queue.calls).to eq(1)
    end

    it 'tolerates tty socket races and console reconnect failures' do
      with_tmpdir do |tmpdir|
        console_dir = File.join(tmpdir, 'console')
        log_path = File.join(tmpdir, 'ct.log')
        sock_path = File.join(console_dir, 'ct1.sock')
        FileUtils.mkdir_p(console_dir)
        File.write(sock_path, '')

        run_conf = Struct.new(:mount, :run_id).new(nil, nil)
        allow(run_conf).to receive(:mount)
        mounts = Struct.new(:added) do
          def prune; end

          def add(mnt)
            added << mnt
          end
        end.new([])
        user = Struct.new(:ugid, :sysusername, :homedir).new(1234, 'alice', tmpdir)
        prlimits = Struct.new(:export).new({})
        lxc_config = Struct.new do
          def configure; end
        end.new
        container = Struct.new(
          :pool,
          :id,
          :state,
          :run_conf,
          :impermanence,
          :distribution,
          :mounts,
          :log_path,
          :user,
          :lxc_config,
          :lxc_home,
          :wrapper_cgroup_path,
          :prlimits,
          keyword_init: true
        ) do
          def can_start?
            true
          end

          def init_run_conf; end

          def syslogns_tag(run_id: nil)
            run_id ? "#{id}:#{run_id}" : id
          end
        end.new(
          pool: Struct.new(:name, :console_dir).new('tank', console_dir),
          id: 'ct1',
          state: :stopped,
          run_conf:,
          impermanence: false,
          distribution: 'almalinux',
          mounts:,
          log_path:,
          user:,
          lxc_config:,
          lxc_home: '/var/lib/lxc',
          wrapper_cgroup_path: '/sys/fs/cgroup/wrapper',
          prlimits:
        )
        console = stub_const('OsCtld::Console', Class.new do
          def self.socket_path(_ct); end

          def self.connect_tty0(*); end
        end)
        dist_config = stub_const('OsCtld::DistConfig', Class.new do
          def self.run(*); end
        end)
        cpu_scheduler = stub_const('OsCtld::CpuScheduler', Class.new do
          def self.schedule_ct(*); end
        end)
        daemon = stub_const('OsCtld::Daemon', Class.new do
          def self.get; end
        end)
        daemon_config = Struct.new(:ct_wrapper).new('/run/wrappers/osctld-ct-wrapper')
        daemon_instance = Struct.new(:config).new(daemon_config)
        allow(OsCtld::SwitchUser).to receive(:clear_ruby_env)
        allow(OsCtld::SwitchUser).to receive(:fork_and_switch_to) do |*_, **_, &block|
          block.call
          101
        end
        allow(console).to receive(:socket_path).with(container).and_return(sock_path)
        allow(console).to receive(:connect_tty0).and_raise(Errno::ECONNREFUSED)
        allow(dist_config).to receive(:run)
        allow(cpu_scheduler).to receive(:schedule_ct)
        allow(daemon).to receive(:get).and_return(daemon_instance)
        OsCtld.define_singleton_method(:bin) { |_name| '/bin/true' } unless OsCtld.respond_to?(:bin)
        allow(OsCtld).to receive(:bin).and_return('/bin/true')
        spawn_args = nil
        allow(Process).to receive(:spawn) do |*args|
          spawn_args = args
          202
        end
        allow(Process).to receive(:wait).with(101)
        allow(File).to receive(:chmod)
        allow(File).to receive(:chown)
        unlinked = false
        allow(File).to receive(:unlink).and_wrap_original do |orig, path|
          if path == sock_path && !unlinked
            unlinked = true
            raise Errno::ENOENT
          else
            orig.call(path)
          end
        end
        command = described_class.new({ debug: false }, {})
        allow(command).to receive(:remove_accounting_cgroups)
        allow(command).to receive(:log)

        expect(command.send(:start_now, container)).to eq(:wait)
        expect(spawn_args[0]).to eq('/run/wrappers/osctld-ct-wrapper')
        expect(command).to have_received(:log).with(:warn, container, 'Unable to connect to tty0')
      end
    end
  end

  describe OsCtld::Commands::Container::Stop do
    let(:autostart_plan) do
      Class.new do
        def stop_ct(_ct); end
      end.new
    end

    let(:pool) { Struct.new(:name, :autostart_plan).new('tank', autostart_plan) }

    def build_stop_container(state: :running, running: true, ephemeral: false, promise: nil)
      run_conf = Struct.new(:init_pid, :promise) do
        def get_exit_promise
          promise
        end
      end.new(promise ? 4321 : nil, promise)
      cgparams = Struct.new do
        attr_reader :expanded

        def temporarily_expand_memory
          @expanded = true
        end
      end.new
      Struct.new(
        :id,
        :pool,
        :state,
        :cgparams,
        :run_conf,
        :cgroup_path,
        keyword_init: true
      ) do
        attr_accessor :running_state, :ephemeral_state, :log_lines

        def running?
          running_state
        end

        def get_run_conf
          run_conf
        end

        def log(level, message)
          log_lines << [level, message]
        end

        def ephemeral?
          ephemeral_state
        end

        def manipulate(_holder, block:, &)
          yield
        end
      end.new(
        id: 'ct1',
        pool:,
        state:,
        cgparams:,
        run_conf:,
        cgroup_path: '/sys/fs/cgroup/osctl/ct.ct1'
      ).tap do |ct|
        ct.running_state = running
        ct.ephemeral_state = ephemeral
        ct.log_lines = []
      end
    end

    before do
      hook = stub_const('OsCtld::Hook', Class.new do
        def self.run(*); end
      end)
      dist_config = stub_const('OsCtld::DistConfig', Class.new do
        def self.run(*, **); end
      end)
      allow(hook).to receive(:run)
      allow(dist_config).to receive(:run)
    end

    it 'maps stop methods to the expected dist-config mode' do
      ct = build_stop_container
      command = described_class.new({ timeout: 10, method: 'kill' }, {})
      allow(command).to receive(:remove_accounting_cgroups)

      expect(command.execute(ct)).to eq(status: true, output: nil)
      expect(OsCtld::DistConfig).to have_received(:run).with(
        ct.get_run_conf,
        :stop,
        mode: :kill,
        message: nil,
        timeout: 10
      )
    end

    it 'switches shutdown_or_kill to kill for frozen containers' do
      ct = build_stop_container(state: :frozen)
      command = described_class.new({ timeout: 10, method: 'shutdown_or_kill' }, {})
      allow(command).to receive(:remove_accounting_cgroups)

      command.execute(ct)

      expect(OsCtld::DistConfig).to have_received(:run).with(
        ct.get_run_conf,
        :stop,
        mode: :kill,
        message: nil,
        timeout: 10
      )
    end

    it 'rejects pure shutdown for frozen containers' do
      ct = build_stop_container(state: :frozen)
      command = described_class.new({ timeout: 10, method: 'shutdown_or_fail' }, {})

      expect { command.execute(ct) }
        .to raise_error(OsCtld::CommandFailed, 'The container is frozen, unable to shutdown')
    end

    it 'aborts when the pre-stop hook fails' do
      ct = build_stop_container
      command = described_class.new({ timeout: 10 }, {})
      hook = Class.new do
        def self.hook_name
          'pre_stop'
        end
      end.new
      allow(OsCtld::Hook).to receive(:run).and_raise(
        OsCtld::HookFailed.new(hook, '/hooks/pre-stop', 1)
      )

      expect { command.execute(ct) }
        .to raise_error(
          OsCtld::CommandFailed,
          'hook pre_stop at /hooks/pre-stop exited with 1'
        )
    end

    it 'forces cleanup when user-runner shutdown fails' do
      ct = build_stop_container
      command = described_class.new({ timeout: 10 }, {})
      allow(OsCtld::DistConfig).to receive(:run)
        .and_raise(OsCtld::ContainerControl::UserRunnerError, 'runner failed')
      allow(command).to receive(:force_kill).with(ct).and_return(true)
      allow(command).to receive(:remove_accounting_cgroups)

      expect(command.execute(ct)).to eq(status: true, output: nil)
      expect(command).to have_received(:force_kill).with(ct)
    end

    it 'maps container-control errors to command failures' do
      ct = build_stop_container
      command = described_class.new({ timeout: 10 }, {})
      allow(OsCtld::DistConfig).to receive(:run)
        .and_raise(OsCtld::ContainerControl::Error, 'stop failed')

      expect { command.execute(ct) }
        .to raise_error(OsCtld::CommandFailed, 'stop failed')
    end

    it 'waits on the exit promise when the init pid is known' do
      promise = double('exit_promise', wait: true)
      ct = build_stop_container(promise:)
      command = described_class.new({ timeout: 10 }, {})
      allow(command).to receive(:remove_accounting_cgroups)

      command.execute(ct)

      expect(promise).to have_received(:wait)
    end

    it 'auto-deletes ephemeral containers only for direct stops' do
      ct = build_stop_container(ephemeral: true)
      delete_class = stub_const('OsCtld::Commands::Container::Delete', Class.new)
      command = described_class.new({ timeout: 10 }, {})
      allow(command).to receive(:remove_accounting_cgroups)
      allow(command).to receive(:call_cmd!).with(
        delete_class,
        pool: 'tank',
        id: 'ct1',
        force: true
      ).and_return(status: true, output: nil)

      expect(command.execute(ct)).to eq(status: true, output: nil)
      expect(command).to have_received(:call_cmd!).with(
        delete_class,
        pool: 'tank',
        id: 'ct1',
        force: true
      )
    end

    it 'does not auto-delete ephemeral containers for indirect stops' do
      ct = build_stop_container(ephemeral: true)
      delete_class = stub_const('OsCtld::Commands::Container::Delete', Class.new)
      command = described_class.new({ timeout: 10 }, { indirect: true })
      allow(command).to receive(:remove_accounting_cgroups)
      allow(command).to receive(:call_cmd!)

      command.execute(ct)

      expect(command).not_to have_received(:call_cmd!).with(
        delete_class,
        anything
      )
    end

    it 'freezes, kills, thaws, and cleans up in order during force_kill' do
      recovery = Class.new do
        attr_reader :events

        def initialize(_ct)
          @events = []
        end

        def kill_all
          events << :kill_all
        end

        def recover_state
          events << :recover_state
        end

        def cleanup_or_taint
          events << :cleanup_or_taint
          true
        end
      end.new(nil)
      recovery_class = stub_const('OsCtld::Container::Recovery', Class.new do
        def self.new(_ct); end
      end)
      cgroup = stub_const('OsCtld::CGroup', Class.new do
        def self.freeze_tree(_path); end

        def self.thaw_tree(_path); end
      end)
      allow(recovery_class).to receive(:new).and_return(recovery)
      allow(cgroup).to receive(:freeze_tree) { recovery.events << :freeze_tree }
      allow(cgroup).to receive(:thaw_tree) { recovery.events << :thaw_tree }
      ct = build_stop_container
      command = described_class.new({}, {})
      allow(command).to receive(:sleep) { |seconds| recovery.events << [:sleep, seconds] }

      expect(command.send(:force_kill, ct)).to be(true)
      expect(recovery.events).to eq(
        [
          :freeze_tree,
          :kill_all,
          :thaw_tree,
          [:sleep, 10],
          :recover_state,
          :cleanup_or_taint
        ]
      )
    end
  end

  describe OsCtld::Commands::Container::Restart do
    it 'reboots through container-control when requested' do
      reboot = stub_const('OsCtld::ContainerControl::Commands::Reboot', Class.new do
        def self.run!(_ct); end
      end)
      allow(reboot).to receive(:run!)
      ct = Struct.new(:pool) do
        def manipulate(_holder, block:, &)
          yield
        end
      end.new(Struct.new(:name).new('tank'))
      command = described_class.new({ reboot: true }, {})

      expect(command.execute(ct)).to eq(status: true, output: nil)
      expect(reboot).to have_received(:run!).with(ct)
    end

    it 'stops and restarts the container with forwarded options' do
      stop_class = stub_const('OsCtld::Commands::Container::Stop', Class.new)
      start_class = stub_const('OsCtld::Commands::Container::Start', Class.new)
      ct = Struct.new(:id, :pool) do
        def manipulate(_holder, block:, &)
          yield
        end
      end.new('ct1', Struct.new(:name).new('tank'))
      command = described_class.new(
        { reboot: false, stop_timeout: 15, stop_method: 'kill', message: 'bye', wait: false },
        {}
      )
      allow(command).to receive(:call_cmd!).with(
        stop_class,
        pool: 'tank',
        id: 'ct1',
        timeout: 15,
        method: 'kill',
        message: 'bye'
      ).and_return(status: true, output: nil)
      allow(command).to receive(:call_cmd!).with(
        start_class,
        pool: 'tank',
        id: 'ct1',
        force: true,
        wait: false
      ).and_return(status: true, output: nil)

      expect(command.execute(ct)).to eq(status: true, output: nil)
    end
  end

  describe OsCtld::Commands::Container::Boot do
    def build_boot_container(pool:, run_conf:, rootfs: '/rootfs')
      mounts = Struct.new(:entries) do
        def find_at(path)
          entries[path]
        end
      end.new({})
      Struct.new(
        :id,
        :pool,
        :dataset,
        :distribution,
        :version,
        :arch,
        :vendor,
        :variant,
        :rootfs,
        :mounts,
        keyword_init: true
      ) do
        attr_accessor :running_state, :events, :new_run_conf_obj

        def running?
          running_state
        end

        def mount(force: false)
          events << [:mount, force]
        end

        def new_run_conf
          new_run_conf_obj
        end

        def set_next_run_conf(ctrc)
          events << [:set_next_run_conf, ctrc]
        end

        def manipulate(_holder, block:, &)
          events << :manipulate_enter
          yield
        ensure
          events << :manipulate_exit
        end
      end.new(
        id: 'ct1',
        pool:,
        dataset: 'tank/ct1',
        distribution: 'almalinux',
        version: '9',
        arch: 'x86_64',
        vendor: 'custom-vendor',
        variant: 'special',
        rootfs:,
        mounts:
      ).tap do |ct|
        ct.running_state = false
        ct.events = []
        ct.new_run_conf_obj = run_conf
      end
    end

    before do
      mount_entry = stub_const('OsCtld::Mount::Entry', Class.new do
        def initialize(*); end
      end)
      allow(mount_entry).to receive(:new).and_call_original
    end

    it 'rejects rootfs mount conflicts with persistent mounts' do
      pool = Struct.new(:name).new('tank')
      run_conf = double('RunConf')
      ct = build_boot_container(pool:, run_conf:)
      ct.mounts.entries['/mnt/root'] = Struct.new(:temp).new(false)
      command = described_class.new(
        { mount_root: '/mnt/root', type: 'image', path: '/tmp/image.tar' },
        {}
      )

      expect { command.execute(ct) }
        .to raise_error(OsCtld::CommandFailed, /unable to mount rootfs/)
    end

    it 'fills missing remote image attributes from the target container and starts queued boots after unlocking' do
      with_tmpdir do |tmpdir|
        image_path = File.join(tmpdir, 'image.tar')
        File.write(image_path, 'image')
        pool = Struct.new(:name).new('tank')
        run_conf = Struct.new do
          def boot_from(**opts)
            @boot_opts = opts
          end

          attr_reader :boot_opts
        end.new
        ct = build_boot_container(pool:, run_conf:)
        tmp_ds = instance_double(OsCtl::Lib::Zfs::Dataset, create!: nil)
        dataset_class = stub_const('OsCtl::Lib::Zfs::Dataset', Class.new do
          def self.new(*); end
        end)
        builder_class = stub_const('OsCtld::Container::Builder', Class.new do
          def self.new(*); end
        end)
        importer_class = stub_const('OsCtld::Container::Importer', Class.new do
          def self.new(*); end
        end)
        builder = instance_double(builder_class, shift_or_mount_dataset: nil, setup_ct_dir: nil, setup_rootfs: nil)
        importer = instance_double(
          importer_class,
          load_metadata: nil,
          get_container_config: {},
          import_root_dataset: nil
        )
        gc = stub_const('OsCtld::GarbageCollector', Class.new do
          def self.add_container_run_dataset(*); end
        end)
        allow(dataset_class).to receive(:new).and_return(tmp_ds)
        allow(builder_class).to receive(:new).and_return(builder)
        allow(importer_class).to receive(:new).and_return(importer)
        allow(gc).to receive(:add_container_run_dataset)
        command = described_class.new(
          {
            type: 'remote',
            image: {},
            queue: true,
            wait: false,
            priority: 3
          },
          {}
        )
        allow(command).to receive(:with_image_path) do |pool_arg, type:, path:, image:, &block|
          expect(pool_arg).to eq(pool)
          expect(type).to eq('remote')
          expect(path).to be_nil
          expect(image).to eq(
            distribution: 'almalinux',
            version: '9',
            arch: 'x86_64',
            vendor: 'custom-vendor',
            variant: 'special'
          )
          block.call(image_path)
        end
        allow(command).to receive(:call_cmd!).with(
          OsCtld::Commands::Container::Stop,
          pool: 'tank',
          id: 'ct1'
        ).and_return(status: true, output: nil)
        allow(command).to receive(:start_ct) do |_, _|
          ct.events << [:start_ct, ct.events.last != :manipulate_exit]
          { status: true, output: nil }
        end

        expect(command.execute(ct)).to eq(status: true, output: nil)
        expect(gc).to have_received(:add_container_run_dataset).with(run_conf, tmp_ds)
        expect(ct.events).to include([:set_next_run_conf, run_conf])
        expect(ct.events.last).to eq([:start_ct, false])
      end
    end
  end

  describe OsCtld::Commands::Container::Delete do
    let(:stop_class) { stub_const('OsCtld::Commands::Container::Stop', Class.new) }
    let(:user_delete_class) { stub_const('OsCtld::Commands::User::Delete', Class.new) }
    let(:lxc_usernet_class) { stub_const('OsCtld::Commands::User::LxcUsernet', Class.new) }

    def build_delete_container(root:)
      trash_bin = Struct.new do
        def prune; end
      end.new
      autostart_plan = Struct.new do
        attr_reader :cleared

        def clear_ct(ct)
          @cleared = ct
        end
      end.new
      pool = Struct.new(:name, :trash_bin, :autostart_plan).new('tank', trash_bin, autostart_plan)
      shared_dir = Struct.new do
        attr_reader :removed

        def remove
          @removed = true
        end
      end.new
      mounts = Struct.new(:shared_dir).new(shared_dir)
      send_log = Struct.new(:opts).new(Struct.new(:key_name).new('tx'))
      user = Struct.new(:standalone, :pool, :name) do
        def has_containers?
          false
        end
      end.new(false, pool, 'alice')
      group_dir = File.join(root, 'group')
      FileUtils.mkdir_p(group_dir)
      lxc_dir = File.join(root, 'lxc')
      hook_dir = File.join(root, 'hooks')
      FileUtils.mkdir_p(lxc_dir)
      FileUtils.mkdir_p(hook_dir)
      config_path = File.join(root, 'ct.yml')
      log_path = File.join(root, 'ct.log')
      File.write(config_path, 'cfg')
      File.write(log_path, 'log')
      Struct.new(
        :id,
        :pool,
        :mounts,
        :send_log,
        :dataset,
        :lxc_dir,
        :user_hook_script_dir,
        :log_path,
        :config_path,
        :group,
        :user,
        :base_cgroup_path,
        keyword_init: true
      ) do
        attr_accessor :clear_start_menu_calls, :running_state

        def running?
          running_state
        end

        def clear_start_menu
          self.clear_start_menu_calls += 1
        end

        def log(*); end

        def manipulate(_holder, block:, &)
          yield
        end

        def exclusively(&block)
          block.call
        end
      end.new(
        id: 'ct1',
        pool:,
        mounts:,
        send_log:,
        dataset: 'tank/ct1',
        lxc_dir:,
        user_hook_script_dir: hook_dir,
        log_path:,
        config_path:,
        group: Struct.new(:userdir_path) do
          def has_containers?(_user)
            false
          end

          def full_cgroup_path(_user)
            '/sys/fs/cgroup/osctl/user.alice'
          end

          def userdir(_user)
            userdir_path
          end
        end.new(group_dir),
        user:,
        base_cgroup_path: '/sys/fs/cgroup/osctl/ct.ct1'
      ).tap do |ct|
        ct.clear_start_menu_calls = 0
        ct.running_state = false
      end
    end

    before do
      build_db_containers
      send_receive = stub_const('OsCtld::SendReceive', Class.new do
        def self.stopped_using_key(*); end
      end)
      console = stub_const('OsCtld::Console', Class.new do
        def self.remove(*); end
      end)
      trash = stub_const('OsCtld::TrashBin', Class.new do
        def self.add_dataset(*); end
      end)
      monitor = stub_const('OsCtld::Monitor::Master', Class.new do
        def self.demonitor(*); end
      end)
      cgroup = stub_const('OsCtld::CGroup', Class.new do
        def self.rmpath_all(*); end
      end)
      apparmor = stub_const('OsCtld::AppArmor', Class.new do
        def self.enabled?
          false
        end
      end)
      allow(send_receive).to receive(:stopped_using_key)
      allow(console).to receive(:remove)
      allow(trash).to receive(:add_dataset)
      allow(monitor).to receive(:demonitor)
      allow(cgroup).to receive(:rmpath_all)
      allow(apparmor).to receive(:enabled?).and_return(false)
      allow(OsCtld::DB::Containers).to receive(:remove)
    end

    def stub_successful_delete_commands(command, message: nil)
      allow(command).to receive(:call_cmd!).with(
        stop_class,
        pool: 'tank',
        id: 'ct1',
        manipulation_lock: nil,
        progress: nil,
        message:
      ).and_return(status: true, output: nil)
      allow(command).to receive(:call_cmd!).with(
        user_delete_class,
        pool: 'tank',
        name: 'alice'
      ).and_return(status: true, output: nil)
      allow(command).to receive(:call_cmd).with(lxc_usernet_class).and_return(status: true, output: nil)
      allow(command).to receive(:syscmd)
    end

    it 'rejects running containers unless force is set' do
      with_tmpdir do |tmpdir|
        ct = build_delete_container(root: tmpdir)
        ct.running_state = true

        expect { described_class.new({}, {}).execute(ct) }
          .to raise_error(OsCtld::CommandFailed, 'the container is running')
      end
    end

    it 'stops, unregisters, cleans up, and prunes when requested' do
      with_tmpdir do |tmpdir|
        ct = build_delete_container(root: tmpdir)
        command = described_class.new({ prune: true, message: 'bye' }, {})
        allow(ct.pool.trash_bin).to receive(:prune)
        stub_successful_delete_commands(command, message: 'bye')

        expect(command.execute(ct)).to eq(status: true, output: nil)
        expect(OsCtld::SendReceive).to have_received(:stopped_using_key).with(ct.pool, 'tx')
        expect(OsCtld::Console).to have_received(:remove).with(ct)
        expect(OsCtld::TrashBin).to have_received(:add_dataset).with(ct.pool, 'tank/ct1')
        expect(OsCtld::Monitor::Master).to have_received(:demonitor).with(ct)
        expect(OsCtld::DB::Containers).to have_received(:remove).with(ct)
        expect(OsCtld::CGroup).to have_received(:rmpath_all).with('/sys/fs/cgroup/osctl/user.alice')
        expect(ct.clear_start_menu_calls).to eq(1)
        expect(ct.mounts.shared_dir.removed).to be(true)
        expect(ct.pool.autostart_plan.cleared).to equal(ct)
        expect(ct.pool.trash_bin).to have_received(:prune)
      end
    end

    it 'unregisters the container when its dataset is already missing' do
      with_tmpdir do |tmpdir|
        ct = build_delete_container(root: tmpdir)
        command = described_class.new({}, {})
        stub_successful_delete_commands(command)
        allow(OsCtld::TrashBin).to receive(:add_dataset).and_raise(
          OsCtld::SystemCommandFailed.new(
            'zfs list tank/ct1',
            1,
            "cannot open 'tank/ct1': dataset does not exist\n"
          )
        )

        expect(command.execute(ct)).to eq(status: true, output: nil)
        expect(OsCtld::DB::Containers).to have_received(:remove).with(ct)
        expect(OsCtld::Monitor::Master).to have_received(:demonitor).with(ct)
      end
    end
  end

  describe OsCtld::Commands::Container::Freeze do
    it 'returns an error when the container cannot be found' do
      db = build_db_containers
      allow(db).to receive(:find).with('ct1', 'tank').and_return(nil)

      expect(described_class.run(id: 'ct1', pool: 'tank')).to eq(
        status: false,
        message: 'container not found'
      )
    end

    it 'delegates freezing to container-control only when needed' do
      db = build_db_containers
      freeze_cmd = stub_const('OsCtld::ContainerControl::Commands::Freeze', Class.new do
        def self.run!(_ct); end
      end)
      ct = Struct.new(:state) do
        def manipulate(_holder, block:, &)
          yield
        end
      end.new(:running)
      allow(db).to receive(:find).with('ct1', 'tank').and_return(ct)
      allow(freeze_cmd).to receive(:run!)

      expect(described_class.run(id: 'ct1', pool: 'tank')).to eq(status: true, output: nil)
      expect(freeze_cmd).to have_received(:run!).with(ct)
    end
  end

  describe OsCtld::Commands::Container::Unfreeze do
    it 'returns ok without delegating when the container is already running' do
      db = build_db_containers
      thaw_cmd = stub_const('OsCtld::ContainerControl::Commands::Unfreeze', Class.new do
        def self.run!(_ct); end
      end)
      ct = Struct.new(:state) do
        def manipulate(_holder, block:, &)
          yield
        end
      end.new(:running)
      allow(db).to receive(:find).with('ct1', 'tank').and_return(ct)
      allow(thaw_cmd).to receive(:run!)

      expect(described_class.run(id: 'ct1', pool: 'tank')).to eq(status: true, output: nil)
      expect(thaw_cmd).not_to have_received(:run!)
    end
  end

  describe OsCtld::Commands::Container::Reconfigure do
    it 'reconfigures the resolved container' do
      db = build_db_containers
      lxc_config = Struct.new do
        attr_reader :configured

        def configure
          @configured = true
        end
      end.new
      ct = Struct.new(:lxc_config) do
        def manipulate(_holder, block:, &)
          yield
        end
      end.new(lxc_config)
      allow(db).to receive(:find).with('ct1', 'tank').and_return(ct)

      expect(described_class.run(id: 'ct1', pool: 'tank')).to eq(status: true, output: nil)
      expect(lxc_config.configured).to be(true)
    end
  end
end

# rubocop:enable Lint/ConstantDefinitionInBlock, Lint/StructNewOverride, RSpec/DescribeClass, RSpec/LeakyConstantDeclaration, RSpec/VerifiedDoubles
