# frozen_string_literal: true

require 'osctld/exceptions'
require 'osctld/command'
require 'osctld/commands/base'
require 'osctld/commands/logged'

RSpec.describe OsCtld::Commands::Logged do
  around do |example|
    snapshot = OsCtld::Command.class_variable_get(:@@commands).transform_values(&:dup)
    example.run
  ensure
    OsCtld::Command.class_variable_set(:@@commands, snapshot)
  end

  before do
    stub_const('OsCtld::History', Class.new do
      def self.log(*); end
    end)
    allow(OsCtld::History).to receive(:log)

    stub_const('OsCtld::Pool', Class.new)
  end

  it 'logs successful direct commands for pools' do
    pool = OsCtld::Pool.new

    klass = Class.new(described_class) do
      handle :spec_logged_pool

      define_method(:find) { pool }
      define_method(:execute) { |_obj| ok('done') }
    end

    ret = klass.run(internal: { id: 1 }, foo: 'bar')

    expect(ret).to eq(status: true, output: 'done')
    expect(OsCtld::History).to have_received(:log).with(
      pool,
      :spec_logged_pool,
      hash_including(foo: 'bar')
    )
  end

  it 'logs successful direct commands for objects that expose pool' do
    pool = OsCtld::Pool.new
    obj = Struct.new(:pool).new(pool)

    klass = Class.new(described_class) do
      handle :spec_logged_object

      define_method(:find) { obj }
      define_method(:execute) { |_found| ok('done') }
    end

    klass.run(internal: { id: 1 }, foo: 'bar')

    expect(OsCtld::History).to have_received(:log).with(
      pool,
      :spec_logged_object,
      hash_including(foo: 'bar')
    )
  end

  it 'does not log failed command executions' do
    pool = OsCtld::Pool.new

    klass = Class.new(described_class) do
      handle :spec_logged_failure

      define_method(:find) { pool }
      define_method(:execute) { |_obj| error('boom') }
    end

    expect(klass.run(internal: { id: 1 })).to eq(status: false, message: 'boom')
    expect(OsCtld::History).not_to have_received(:log)
  end

  it 'does not log indirect command executions' do
    pool = OsCtld::Pool.new

    klass = Class.new(described_class) do
      handle :spec_logged_indirect

      define_method(:find) { pool }
      define_method(:execute) { |_obj| ok('done') }
    end

    klass.run(internal: { id: 1, indirect: true })

    expect(OsCtld::History).not_to have_received(:log)
  end
end
