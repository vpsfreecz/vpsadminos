# frozen_string_literal: true

require 'libosctl'
require 'osctld/exceptions'
require 'osctld/lock_registry'
require 'osctld/lockable'

RSpec.describe OsCtld::Lockable do
  subject(:fixture) { fixture_class.new }

  let(:fixture_class) do
    Class.new do
      include OsCtld::Lockable

      attr_inclusive_reader :reader_value
      attr_exclusive_writer :writer_value
      attr_synchronized_accessor :value

      def initialize
        init_lock
        @reader_value = 5
        @writer_value = 0
        @value = 0
      end

      def raw_writer_value
        @writer_value
      end
    end
  end

  before do
    allow(OsCtld::LockRegistry).to receive(:register)
  end

  def wait_for_event(queue, type)
    loop do
      event = pop_with_timeout(queue)
      return event if event.first == type
    end
  end

  it 'provides synchronized readers, writers, and accessors' do
    fixture.writer_value = 12
    fixture.value = 7

    expect(fixture.reader_value).to eq(5)
    expect(fixture.raw_writer_value).to eq(12)
    expect(fixture.value).to eq(7)
  end

  it 'supports ro and rw aliases for lock and unlock' do
    fixture.lock(:ro)
    expect(fixture.reader_value).to eq(5)
    fixture.unlock(:ro)

    fixture.lock(:rw)
    fixture.value = 3
    fixture.unlock(:rw)

    expect(fixture.value).to eq(3)
  end

  it 'raises on unknown lock types' do
    expect { fixture.lock(:invalid) }.to raise_error(RuntimeError, /unknown lock type/)
    expect { fixture.unlock(:invalid) }.to raise_error(RuntimeError, /unknown lock type/)
  end

  it 'allows nested inclusive locks in the same thread' do
    seen = []

    fixture.inclusively do
      seen << fixture.reader_value
      fixture.inclusively { seen << fixture.reader_value }
    end

    expect(seen).to eq([5, 5])
  end

  it 'allows nested exclusive locks in the same thread' do
    fixture.exclusively do
      fixture.value = 2
      fixture.exclusively { fixture.value = 4 }
    end

    expect(fixture.value).to eq(4)
  end

  it 'allows inclusive work inside an exclusive block' do
    fixture.value = 9

    fixture.exclusively do
      expect(fixture.value).to eq(9)
    end
  end

  it 'raises when acquiring an exclusive lock while holding an inclusive lock' do
    expect do
      fixture.inclusively do
        fixture.exclusively { fixture.reader_value }
      end
    end.to raise_error(RuntimeError, /attempted to acquire exclusive lock while holding inclusive lock/)
  end

  it 'blocks a later inclusive lock behind a queued exclusive lock' do
    events = Queue.new
    order = Queue.new
    release_exclusive = Queue.new

    allow(OsCtld::LockRegistry).to receive(:register) do |_object, type, state|
      events << [type, state]
    end

    fixture.lock(:ro)

    exclusive = Thread.new do
      fixture.exclusively do
        order << :exclusive_locked
        pop_with_timeout(release_exclusive)
      end
    end

    expect(wait_for_event(events, :exclusive)).to eq(%i[exclusive waiting])

    inclusive = Thread.new do
      fixture.inclusively do
        order << :inclusive_locked
      end
    end

    expect(wait_for_event(events, :inclusive)).to eq(%i[inclusive waiting])

    fixture.unlock(:ro)

    expect(pop_with_timeout(order)).to eq(:exclusive_locked)

    release_exclusive << true

    expect(pop_with_timeout(order)).to eq(:inclusive_locked)

    [exclusive, inclusive].each(&:join)
  end

  it 'releases helper locks even when the block raises' do
    expect do
      fixture.inclusively { raise 'inclusive failure' }
    end.to raise_error(RuntimeError, 'inclusive failure')

    expect do
      fixture.exclusively { raise 'exclusive failure' }
    end.to raise_error(RuntimeError, 'exclusive failure')

    expect { fixture.inclusively { fixture.reader_value } }.not_to raise_error
    expect { fixture.exclusively { fixture.value = 10 } }.not_to raise_error
    expect(fixture.value).to eq(10)
  end
end
