# frozen_string_literal: true

# rubocop:disable RSpec/SubjectStub

require 'osctld/lock_registry'

RSpec.describe OsCtld::LockRegistry do
  subject(:registry) { fresh_singleton(described_class) }

  before do
    allow(OsCtl::Lib::Logger).to receive(:log)
  end

  after do
    registry.stop
  rescue StandardError
    nil
  end

  def build_lock(type:, state:, thread: Thread.current, object: Object.new, backtrace: ['/nix/store/a'])
    described_class::Lock.new(
      1,
      Time.now,
      thread,
      object,
      type,
      state,
      backtrace
    )
  end

  it 'allows setup to be called only once' do
    registry.setup(false)

    expect do
      registry.setup(true)
    end.to raise_error(RuntimeError, /setup can be called only once/)
  end

  it 'returns empty exports and does not start a worker thread when disabled' do
    allow(Thread).to receive(:new)

    registry.setup(false)

    expect(registry.enabled?).to be(false)
    expect(registry.export).to eq([])
    expect(Thread).not_to have_received(:new)
  end

  it 'deduplicates duplicate exclusive waiting locks' do
    thread = Object.new
    object = Object.new
    first = build_lock(type: :exclusive, state: :waiting, thread:, object:)
    second = build_lock(type: :exclusive, state: :waiting, thread:, object:)

    registry.send(:do_register, first)
    registry.send(:do_register, second)

    expect(registry.send(:registry)).to eq([first])
  end

  it 'upgrades a waiting lock to locked when the same lock is acquired' do
    thread = Object.new
    object = Object.new
    waiting = build_lock(type: :inclusive, state: :waiting, thread:, object:, backtrace: ['/nix/store/wait'])
    locked = build_lock(type: :inclusive, state: :locked, thread:, object:, backtrace: ['/nix/store/lock'])

    registry.send(:do_register, waiting)
    registry.send(:do_register, locked)

    expect(registry.send(:registry).size).to eq(1)
    expect(registry.send(:registry).first.state).to eq(:locked)
    expect(registry.send(:registry).first.backtrace).to eq(['/nix/store/lock'])
  end

  it 'removes matching locks on unlock and timeout' do
    thread = Object.new
    object = Object.new

    %i[unlocked timeout].each do |terminal_state|
      reg = fresh_singleton(described_class)
      reg.send(:do_register, build_lock(type: :exclusive, state: :locked, thread:, object:))
      reg.send(:do_register, build_lock(type: :exclusive, state: terminal_state, thread:, object:))

      expect(reg.send(:registry)).to be_empty
    end
  end

  it 'logs exported lock entries with denixstorified backtraces' do
    registry.instance_variable_set(:@enabled, true)
    allow(registry).to receive(:export).and_return([
                                                     {
                                                       id: 7,
                                                       thread: 'thr',
                                                       type: :exclusive,
                                                       state: :locked,
                                                       backtrace: ['/nix/store/abc', '/tmp/xyz']
                                                     }
                                                   ])
    allow(registry).to receive(:denixstorify).with(['/nix/store/abc', '/tmp/xyz']).and_return(%w[abc /tmp/xyz])

    registry.dump

    expect(OsCtl::Lib::Logger).to have_received(:log).with(:debug, '[locks] Dumping lock registry')
    expect(OsCtl::Lib::Logger).to have_received(:log).with(
      :debug,
      '[locks] id=7,thread=thr,type=exclusive,state=locked'
    )
    expect(OsCtl::Lib::Logger).to have_received(:log).with(:debug, "[locks] abc\n/tmp/xyz")
    expect(OsCtl::Lib::Logger).to have_received(:log).with(:debug, '[locks] End of dump')
  end
end

# rubocop:enable RSpec/SubjectStub
