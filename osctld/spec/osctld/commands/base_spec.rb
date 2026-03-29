# frozen_string_literal: true

require 'osctld/exceptions'
require 'osctld/command'
require 'osctld/commands/base'

RSpec.describe OsCtld::Commands::Base do
  around do |example|
    snapshot = OsCtld::Command.class_variable_get(:@@commands).transform_values(&:dup)
    example.run
  ensure
    OsCtld::Command.class_variable_set(:@@commands, snapshot)
  end

  def build_handler
    handler_class = Class.new do
      def socket; end

      def send_update(_msg); end
    end

    instance_double(handler_class, socket: nil, send_update: nil)
  end

  def build_manipulable
    manipulable_class = Class.new do
      def acquire_manipulation_lock(_holder, block: false); end

      def release_manipulation_lock; end
    end

    instance_double(manipulable_class)
  end

  it 'registers the handled command name' do
    cmd_name = :spec_base_handle

    klass = Class.new(described_class) do
      handle cmd_name

      def execute
        ok
      end
    end

    expect(OsCtld::Command.find(cmd_name)).to eq(klass)
  end

  it 'runs the command and returns its result' do
    klass = Class.new(described_class) do
      handle :spec_base_run

      class << self
        attr_accessor :seen
      end

      def execute
        self.class.seen = {
          id:,
          opts:,
          client:
        }
        ok('done')
      end
    end

    ret = klass.run(internal: { id: 101 }, foo: 'bar')

    expect(ret).to eq(status: true, output: 'done')
    expect(klass.seen[:id]).to eq(101)
    expect(klass.seen[:opts]).to include(foo: 'bar')
    expect(klass.seen[:client]).to be_nil
  end

  it 'keeps the generated internal command id separate from command kwargs' do
    klass = Class.new(described_class) do
      handle :spec_base_internal_id

      class << self
        attr_accessor :seen
      end

      def execute
        self.class.seen = { id:, opts: }
        ok
      end
    end

    klass.run(foo: 'bar')

    expect(klass.seen[:id]).to be_a(Integer)
    expect(klass.seen[:opts]).to eq(foo: 'bar')
  end

  it 'returns successful results from run!' do
    klass = Class.new(described_class) do
      handle :spec_base_run_bang_success

      def execute
        ok('done')
      end
    end

    expect(klass.run!).to eq(status: true, output: 'done')
  end

  it 'raises on failed results from run!' do
    klass = Class.new(described_class) do
      handle :spec_base_run_bang

      def execute
        error('boom')
      end
    end

    expect { klass.run! }.to raise_error('boom')
  end

  it 'raises on invalid non-hash results from run!' do
    klass = Class.new(described_class) do
      handle :spec_base_run_bang_invalid

      def execute
        :nope
      end
    end

    expect { klass.run! }.to raise_error(/invalid return value/)
  end

  it 'forwards the current handler and marks nested commands indirect' do
    nested = Class.new do
      def self.run(internal:, **kwargs)
        { status: true, output: { internal:, kwargs: } }
      end
    end

    handler = build_handler

    klass = Class.new(described_class) do
      handle :spec_base_call_cmd

      def execute
        call_cmd(self.class::Nested, foo: 'bar')
      end
    end

    klass.const_set(:Nested, nested)

    ret = klass.run(internal: { id: 1, handler: }, foo: 'ignored')

    expect(ret[:output][:internal]).to include(handler:, indirect: true)
    expect(ret[:output][:kwargs]).to eq(foo: 'bar')
  end

  it 'raises CommandFailed when nested command returns failure' do
    nested = Class.new do
      def self.run(**)
        { status: false, message: 'nested failed' }
      end
    end

    klass = Class.new(described_class) do
      handle :spec_base_call_cmd_bang

      def trigger_call_cmd_bang
        call_cmd!(self.class::Nested)
      end

      def execute
        ok
      end
    end

    klass.const_set(:Nested, nested)
    cmd = klass.new({}, { id: 1 })

    expect do
      cmd.trigger_call_cmd_bang
    end.to raise_error(OsCtld::CommandFailed, 'nested failed')
  end

  it 'sends progress updates through the client handler' do
    handler = build_handler

    klass = Class.new(described_class) do
      handle :spec_base_progress

      def execute
        progress('half way')
        ok
      end
    end

    klass.run(internal: { id: 1, handler: }, progress: true)

    expect(handler).to have_received(:send_update).with('half way')
  end

  it 'does not send progress updates when progress reporting is disabled' do
    handler = build_handler

    klass = Class.new(described_class) do
      handle :spec_base_progress_disabled

      def execute
        progress('half way')
        ok
      end
    end

    klass.run(internal: { id: 1, handler: }, progress: false)

    expect(handler).not_to have_received(:send_update)
  end

  it 'treats progress as a no-op without a client handler' do
    klass = Class.new(described_class) do
      handle :spec_base_progress_no_handler

      def execute
        progress('half way')
        ok('done')
      end
    end

    expect(klass.run(internal: { id: 1 }, progress: true)).to eq(status: true, output: 'done')
  end

  it 'releases already acquired locks when later acquisition fails' do
    m1 = build_manipulable
    m2 = build_manipulable
    resource_locked = OsCtld::ResourceLocked.new(Object.new, Object.new)

    allow(m1).to receive(:acquire_manipulation_lock).and_return(true)
    allow(m1).to receive(:release_manipulation_lock)
    allow(m2).to receive(:acquire_manipulation_lock).and_raise(resource_locked)

    cmd = Class.new(described_class) do
      handle :spec_base_manipulate_failure

      def execute
        ok
      end
    end.new({}, { id: 1 })

    expect do
      cmd.send(:manipulate, [m1, m2]) { nil }
    end.to raise_error(OsCtld::ResourceLocked)

    expect(m1).to have_received(:release_manipulation_lock)
  end

  it 'acquires and releases all locks on success' do
    m1 = build_manipulable
    m2 = build_manipulable

    allow(m1).to receive(:acquire_manipulation_lock).and_return(true)
    allow(m1).to receive(:release_manipulation_lock)
    allow(m2).to receive(:acquire_manipulation_lock).and_return(true)
    allow(m2).to receive(:release_manipulation_lock)

    cmd = Class.new(described_class) do
      handle :spec_base_manipulate_success

      def execute
        ok
      end
    end.new({}, { id: 1 })

    expect(cmd.send(:manipulate, [m1, m2]) { :done }).to eq(:done)
    expect(m1).to have_received(:acquire_manipulation_lock).with(cmd, block: false)
    expect(m2).to have_received(:acquire_manipulation_lock).with(cmd, block: false)
    expect(m1).to have_received(:release_manipulation_lock)
    expect(m2).to have_received(:release_manipulation_lock)
  end

  it 'prefers cli over the command name for manipulation holder' do
    klass = Class.new(described_class) do
      handle :spec_base_holder

      def execute
        ok
      end
    end

    cmd = klass.new({ cli: 'osctl ct ls' }, { id: 1 })

    expect(cmd.send(:manipulation_holder)).to eq("'osctl ct ls'")
  end
end
