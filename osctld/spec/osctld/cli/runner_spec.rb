# frozen_string_literal: true

module OsCtld
  module Cli; end
end

require 'osctld/cli/runner'

RSpec.describe OsCtld::Cli::Runner do
  def with_argv(*args)
    old_argv = ARGV.dup
    ARGV.replace(args)
    yield
  ensure
    ARGV.replace(old_argv)
  end

  it 'prints usage and exits when argv is not empty' do
    with_argv('unexpected') do
      expect do
        described_class.run
      end.to raise_error(SystemExit)
    end
  end

  it 'loads runner config from stdin and writes the result as json' do
    ret = instance_double(IO, puts: nil)
    stdin = instance_double(IO)
    stdout = instance_double(IO)
    stderr = instance_double(IO)
    [ret, stdin, stdout, stderr].each do |io|
      allow(io).to receive(:close_on_exec=)
    end

    runner_class = Class.new do
      class << self
        attr_accessor :instances
      end

      attr_reader :kwargs, :args, :stdin, :stdout, :stderr, :pool, :id, :lxc_home, :user_home, :log_file

      def initialize(pool:, id:, lxc_home:, user_home:, log_file:, stdin:, stdout:, stderr:)
        @pool = pool
        @id = id
        @lxc_home = lxc_home
        @user_home = user_home
        @log_file = log_file
        @stdin = stdin
        @stdout = stdout
        @stderr = stderr
        self.class.instances ||= []
        self.class.instances << self
      end

      def execute(*args, **kwargs)
        @args = args
        @kwargs = kwargs
        { status: true, output: 'done' }
      end
    end
    command_module = Module.new
    command_module.const_set(:Runner, runner_class)
    container_commands = Module.new
    container_commands.const_set(:Sample, command_module)
    stub_const('OsCtld::ContainerControl::Commands', container_commands)
    stub_const('OsCtld::CGroup', Class.new do
      def self.init; end
    end)
    allow(OsCtld::CGroup).to receive(:init)
    allow(OsCtl::Lib::Logger).to receive(:setup)
    allow(Process).to receive(:setproctitle)
    allow(IO).to receive(:new).with(10).and_return(ret)
    allow(IO).to receive(:new).with(11).and_return(stdin)
    allow(IO).to receive(:new).with(12).and_return(stdout)
    allow(IO).to receive(:new).with(13).and_return(stderr)
    allow($stdin).to receive(:readline).and_return({
      pool: 'tank',
      id: 'ct1',
      name: 'Sample',
      lxc_home: '/var/lib/lxc/ct1',
      user_home: '/home/alice',
      log_file: '/var/log/ct1.log',
      return: 10,
      stdin: 11,
      stdout: 12,
      stderr: 13,
      args: ['alpha'],
      kwargs: { debug: true }
    }.to_json)

    with_argv do
      described_class.run
    end

    runner = runner_class.instances.first

    expect(OsCtl::Lib::Logger).to have_received(:setup).with(:none)
    expect(OsCtld::CGroup).to have_received(:init)
    expect(Process).to have_received(:setproctitle).with('osctld: tank:ct1 runner:sample')
    expect(runner.pool).to eq('tank')
    expect(runner.id).to eq('ct1')
    expect(runner.args).to eq(['alpha'])
    expect(runner.kwargs).to eq(debug: true)
    expect(runner.stdin).to equal(stdin)
    expect(runner.stdout).to equal(stdout)
    expect(runner.stderr).to equal(stderr)
    expect(ret).to have_received(:puts).with({ status: true, output: 'done' }.to_json)
  end

  it 'reports runner exceptions through the return pipe' do
    ret = instance_double(IO, puts: nil)
    stdout = instance_double(IO)
    stderr = instance_double(IO)
    [ret, stdout, stderr].each do |io|
      allow(io).to receive(:close_on_exec=)
    end

    runner_class = Class.new do
      def initialize(pool:, id:, lxc_home:, user_home:, log_file:, stdin:, stdout:, stderr:); end

      def execute(*, **)
        raise 'runner exploded'
      end
    end
    command_module = Module.new
    command_module.const_set(:Runner, runner_class)
    container_commands = Module.new
    container_commands.const_set(:Sample, command_module)
    stub_const('OsCtld::ContainerControl::Commands', container_commands)
    stub_const('OsCtld::CGroup', Class.new do
      def self.init; end
    end)
    allow(OsCtl::Lib::Logger).to receive(:setup)
    allow(Process).to receive(:setproctitle)
    allow(IO).to receive(:new).with(10).and_return(ret)
    allow(IO).to receive(:new).with(12).and_return(stdout)
    allow(IO).to receive(:new).with(13).and_return(stderr)
    allow($stdin).to receive(:readline).and_return({
      pool: 'tank',
      id: 'ct1',
      name: 'Sample',
      lxc_home: '/var/lib/lxc/ct1',
      user_home: '/home/alice',
      log_file: '/var/log/ct1.log',
      return: 10,
      stdin: nil,
      stdout: 12,
      stderr: 13,
      args: [],
      kwargs: {}
    }.to_json)

    expect do
      with_argv do
        described_class.run
      end
    end.to raise_error(SystemExit)

    expect(ret).to have_received(:puts) do |payload|
      data = JSON.parse(payload)
      expect(data.fetch('status')).to be(false)
      expect(data.fetch('message')).to include('RuntimeError: runner exploded')
      expect(data.fetch('user_runner')).to be(true)
    end
  end
end
