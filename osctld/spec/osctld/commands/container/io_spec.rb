# frozen_string_literal: true

# rubocop:disable RSpec/DescribeClass, RSpec/ExpectInHook, RSpec/InstanceVariable, RSpec/VerifiedDoubles

require 'stringio'
require 'osctld/exceptions'
require 'osctld/command'
require 'osctld/container_control/command'
require 'osctld/utils/switch_user'
require 'osctld/commands/container/console'
require 'osctld/commands/container/exec'
require 'osctld/commands/container/cat'
require 'osctld/commands/container/attach'
require 'osctld/commands/container/su'
require 'osctld/commands/container/passwd'
require 'osctld/commands/container/wall'
require 'osctld/commands/container/runscript'

RSpec.describe 'container io commands' do
  def build_ct(id: 'ct1', state: :running, running: state == :running, init_pid: 4321)
    pool = Struct.new(:name).new('tank')
    Struct.new(
      :id,
      :pool,
      :user,
      :state,
      :running_state,
      :init_pid,
      :mount_calls,
      :lxc_home,
      :lxc_dir,
      keyword_init: true
    ) do
      def running?
        running_state
      end

      def inclusively
        yield
      end

      def mount
        mount_calls << true
      end

      def get_run_conf
        :run_conf
      end

      def ident
        "#{pool.name}:#{id}"
      end
    end.new(
      id:,
      pool:,
      user: Struct.new(:name).new('alice'),
      state:,
      running_state: running,
      init_pid:,
      mount_calls: [],
      lxc_home: '/var/lib/lxc/ct1',
      lxc_dir: '/var/lib/lxc/ct1'
    )
  end

  def build_handler(client)
    double('handler', socket: client)
  end

  before do
    allow(OsCtl::Lib::Logger).to receive(:log)
  end

  describe OsCtld::Commands::Container::Console do
    let(:client) { double('client', send: nil) }
    let(:handler) { build_handler(client) }
    let(:ct) { build_ct }
    let(:command) { described_class.new({ id: 'ct1', pool: 'tank', tty: 1 }, { handler: }) }

    before do
      db = stub_const('OsCtld::DB::Containers', Class.new do
        def self.find(_id, _pool); end
      end)
      console = stub_const('OsCtld::Console', Class.new do
        def self.client(*); end
      end)
      allow(db).to receive(:find).with('ct1', 'tank').and_return(ct)
      allow(console).to receive(:client)
    end

    it 'sends the continue handshake and hands the client socket to Console.client' do
      expect(command.execute).to eq(status: :handled)
      expect(client).to have_received(:send).with(%({"status":true,"response":"continue"}\n), 0)
      expect(OsCtld::Console).to have_received(:client).with(ct, 1, client)
    end

    it 'allows tty0 even when the container is not running' do
      stopped = build_ct(state: :stopped, running: false)
      allow(OsCtld::DB::Containers).to receive(:find).with('ct1', 'tank').and_return(stopped)
      tty0 = described_class.new({ id: 'ct1', pool: 'tank', tty: 0 }, { handler: })

      expect(tty0.execute).to eq(status: :handled)
    end

    it 'rejects non-console ttys when the container is not running' do
      stopped = build_ct(state: :stopped, running: false)
      allow(OsCtld::DB::Containers).to receive(:find).with('ct1', 'tank').and_return(stopped)

      expect(command.execute).to eq(status: false, message: 'container not running')
    end
  end

  describe OsCtld::Commands::Container::Exec do
    let(:recv_io) { StringIO.new }
    let(:client) { double('client', send: nil, recv_io: recv_io) }
    let(:handler) { build_handler(client) }
    let(:ct) { build_ct }
    let(:command) do
      described_class.new(
        { id: 'ct1', pool: 'tank', cmd: %w[id -u], run: false, network: true },
        { handler: }
      )
    end

    before do
      db = stub_const('OsCtld::DB::Containers', Class.new do
        def self.find(_id, _pool); end
      end)
      exec_class = stub_const('OsCtld::ContainerControl::Commands::Exec', Class.new do
        def self.run!(*, **); end
      end)
      allow(db).to receive(:find).with('ct1', 'tank').and_return(ct)
      allow(exec_class).to receive(:run!).and_return(7)
    end

    it 'sends the handshake, mounts the container, and delegates to container-control exec' do
      expect(command.execute).to eq(status: true, output: { exitstatus: 7 })
      expect(ct.mount_calls).to eq([true])
      expect(client).to have_received(:send).with(%({"status":true,"response":"continue"}\n), 0)
      expect(OsCtld::ContainerControl::Commands::Exec).to have_received(:run!).with(
        ct,
        cmd: %w[id -u],
        run: false,
        network: true,
        stdin: recv_io,
        stdout: recv_io,
        stderr: recv_io
      )
    end

    it 'maps container-control errors to command errors' do
      allow(OsCtld::ContainerControl::Commands::Exec).to receive(:run!)
        .and_raise(OsCtld::ContainerControl::Error, 'exec failed')

      expect(command.execute).to eq(status: false, message: 'exec failed')
    end
  end

  describe OsCtld::Commands::Container::Cat do
    let(:out_io) { StringIO.new }
    let(:client) { double('client', send: nil, recv_io: out_io) }
    let(:handler) { build_handler(client) }
    let(:ct) { build_ct }
    let(:command) do
      described_class.new(
        { id: 'ct1', pool: 'tank', files: [file1, missing] },
        { handler: }
      )
    end

    before do
      db = stub_const('OsCtld::DB::Containers', Class.new do
        def self.find(_id, _pool); end
      end)
      with_mountns = stub_const('OsCtld::ContainerControl::Commands::WithMountns', Class.new do
        def self.run!(*, **); end
      end)
      allow(db).to receive(:find).with('ct1', 'tank').and_return(ct)
      allow(::IO).to receive(:copy_stream) do |src, dst|
        dst.write(src.read)
      end
      allow(with_mountns).to receive(:run!) do |_ct, ns_pid:, stdout:, block:|
        expect(ns_pid).to eq(4321)
        expect(stdout).to equal(out_io)
        block.call
      end
    end

    it 'streams requested files, closes the write end, and returns per-file errors' do
      with_tmpdir do |tmpdir|
        @file1 = File.join(tmpdir, 'hosts')
        @missing = File.join(tmpdir, 'missing')
        File.write(@file1, '127.0.0.1 localhost')

        ret = command.execute

        expect(ret[:status]).to be(true)
        expect(ret[:output][:errors].keys).to eq([@missing])
        expect(ret[:output][:errors][@missing]).to match(/No such file or directory/)
        expect(out_io.string).to eq('127.0.0.1 localhost')
        expect(out_io.closed?).to be(true)
      end
    end

    attr_reader :file1

    attr_reader :missing
  end

  describe OsCtld::Commands::Container::Attach do
    let(:ct) { build_ct }
    let(:command) { described_class.new({ id: 'ct1', pool: 'tank', user_shell: false }, {}) }

    before do
      db = stub_const('OsCtld::DB::Containers', Class.new do
        def self.find(_id, _pool); end
      end)
      switch_user = stub_const('OsCtld::SwitchUser', Module.new)
      switch_user.const_set(:SYSTEM_PATH, %w[/run/current-system/sw/bin /bin])
      allow(db).to receive(:find).with('ct1', 'tank').and_return(ct)
    end

    it 'chooses bash when available and formats the prompt accordingly' do
      shell = described_class::Shell.new(:bash, '/bin/bash')
      allow(command).to receive(:find_shell).with(ct).and_return(shell)
      allow(command).to receive(:ct_attach).and_return(cmd: 'attach')

      expect(command.execute).to eq(status: true, output: { cmd: 'attach' })
      expect(command).to have_received(:ct_attach).with(
        ct,
        'lxc-attach', '-P', '/var/lib/lxc/ct1',
        '-n', 'ct1',
        '--clear-env',
        '--keep-var', 'TERM',
        '-v', 'USER=root',
        '-v', 'LOGNAME=root',
        '-v', 'HOME=/root',
        '-v', 'PATH=/run/current-system/sw/bin:/bin',
        '-v', 'HISTFILE=/root/.osctl_ct_attach_history',
        '--keep-var', 'LANG',
        '-v', "PS1=#{command.send(:prompt, ct, shell)}",
        '--',
        '/bin/bash', '--norc',
        lifecycle: true
      )
    end

    it 'returns an error when no supported shell can be found' do
      allow(command).to receive(:find_shell).with(ct).and_return(nil)

      expect { command.execute }.to raise_error(OsCtld::CommandFailed, 'no supported shell located')
    end

    it 'returns busybox and sh shell arguments and prompts' do
      busybox = described_class::Shell.new(:busybox, '/bin/busybox')
      sh = described_class::Shell.new(:sh, '/bin/sh')

      expect(command.send(:shell_args, busybox)).to eq(['/bin/busybox', 'sh'])
      expect(command.send(:shell_args, sh)).to eq(['/bin/sh'])
      expect(command.send(:prompt, ct, busybox)).to eq('\\n[CT ct1] \\u@\\h:\\w\\$ ')
      expect(command.send(:prompt, ct, sh)).to eq('\\n[CT ct1] $USER@$HOSTNAME:$PWD\\$ ')
    end
  end

  describe OsCtld::Commands::Container::Su do
    it 'attaches to the container shell through ct_attach' do
      ct = build_ct
      db = stub_const('OsCtld::DB::Containers', Class.new do
        def self.find(_id, _pool); end
      end)
      allow(db).to receive(:find).with('ct1', 'tank').and_return(ct)
      command = described_class.new({ id: 'ct1', pool: 'tank' }, {})
      allow(command).to receive(:ct_attach).and_return(cmd: 'bash')

      expect(command.execute).to eq(status: true, output: { cmd: 'bash' })
      expect(command).to have_received(:ct_attach).with(
        ct,
        'bash',
        '--rcfile',
        '/var/lib/lxc/ct1/.bashrc',
        cgroup_path: 'osctl/admin/pool.tank/user.alice'
      )
    end
  end

  describe OsCtld::Commands::Container::Passwd do
    let(:ct) { build_ct }
    let(:command) do
      described_class.new({ id: 'ct1', pool: 'tank', user: 'root', password: 'secret' }, {})
    end

    before do
      db = stub_const('OsCtld::DB::Containers', Class.new do
        def self.find(_id, _pool); end
      end)
      dist_config = stub_const('OsCtld::DistConfig', Class.new do
        def self.run(*, **); end
      end)
      allow(db).to receive(:find).with('ct1', 'tank').and_return(ct)
      allow(command).to receive(:manipulate).and_yield
      allow(dist_config).to receive(:run)
    end

    it 'delegates to DistConfig passwd and reports success and boolean failure' do
      allow(OsCtld::DistConfig).to receive(:run).and_return(true, false)

      expect(command.execute).to eq(status: true, output: nil)
      expect(command.execute).to eq(status: false, message: 'unable to set password for root')
      expect(OsCtld::DistConfig).to have_received(:run).with(
        :run_conf,
        :passwd,
        user: 'root',
        password: 'secret'
      ).twice
    end
  end

  describe OsCtld::Commands::Container::Wall do
    it 'iterates containers, skips stopped ones, logs errors, and still returns ok' do
      running = build_ct(id: 'running')
      stopped = build_ct(id: 'stopped', state: :stopped, running: false)
      failing = build_ct(id: 'failing')
      db = stub_const('OsCtld::DB::Containers', Class.new do
        def self.each_by_ids(_ids, _pool); end
      end)
      wall = stub_const('OsCtld::ContainerControl::Commands::Wall', Class.new do
        def self.run!(*, **); end
      end)
      execution_plan_class = Class.new do
        attr_reader :items

        def initialize
          @items = []
        end

        def <<(ct)
          @items << ct
        end

        def run(&block)
          items.each(&block)
        end

        def wait; end
      end
      stub_const('OsCtld::ExecutionPlan', execution_plan_class)
      allow(db).to receive(:each_by_ids).with(%w[running stopped failing], 'tank').and_yield(running).and_yield(stopped).and_yield(failing)
      allow(wall).to receive(:run!).with(running, message: 'hello', banner: true)
      allow(wall).to receive(:run!).with(failing, message: 'hello', banner: true)
                                   .and_raise(OsCtld::ContainerControl::Error, 'wall failed')
      command = described_class.new(
        { ids: %w[running stopped failing], pool: 'tank', message: 'hello', banner: true },
        {}
      )

      expect(command.execute).to eq(status: true, output: nil)
      expect(wall).to have_received(:run!).with(running, message: 'hello', banner: true)
      expect(wall).not_to have_received(:run!).with(stopped, anything)
      expect(OsCtl::Lib::Logger).to have_received(:log).with(
        :info,
        '[ct-wall] Error from ct tank:failing: wall failed'
      )
    end
  end

  describe OsCtld::Commands::Container::Runscript do
    let(:recv_io) { StringIO.new }
    let(:client) { double('client', send: nil, recv_io: recv_io) }
    let(:handler) { build_handler(client) }
    let(:ct) { build_ct }
    let(:command) do
      described_class.new(
        { id: 'ct1', pool: 'tank', script: 'echo ok', arguments: %w[a b], run: true, network: false },
        { handler: }
      )
    end

    before do
      db = stub_const('OsCtld::DB::Containers', Class.new do
        def self.find(_id, _pool); end
      end)
      runscript = stub_const('OsCtld::ContainerControl::Commands::Runscript', Class.new do
        def self.run!(*, **); end
      end)
      allow(db).to receive(:find).with('ct1', 'tank').and_return(ct)
      allow(runscript).to receive(:run!).and_return(9)
    end

    it 'sends the handshake and delegates to runscript execution' do
      expect(command.execute).to eq(status: true, output: { exitstatus: 9 })
      expect(client).to have_received(:send).with(%({"status":true,"response":"continue"}\n), 0)
      expect(OsCtld::ContainerControl::Commands::Runscript).to have_received(:run!).with(
        ct,
        script: 'echo ok',
        args: %w[a b],
        run: true,
        network: false,
        stdin: recv_io,
        stdout: recv_io,
        stderr: recv_io
      )
    end
  end
end

# rubocop:enable RSpec/DescribeClass, RSpec/ExpectInHook, RSpec/InstanceVariable, RSpec/VerifiedDoubles
