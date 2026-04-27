# frozen_string_literal: true

require 'osctld/transfer/log'

RSpec.describe OsCtld::Transfer::Log do
  def log(state = :stage)
    described_class.new(role: :source, state:, snapshots: [], opts: {})
  end

  it 'accepts only known states' do
    l = log

    expect { l.state = :base }.not_to raise_error
    expect { l.state = :unknown }.to raise_error(RuntimeError, /invalid state/)
  end

  it 'allows linear forward transitions' do
    expect(log(:stage).can_continue?(:base)).to be(true)
    expect(log(:base).can_continue?(:incremental)).to be(true)
    expect(log(:incremental).can_continue?(:transfer)).to be(true)
    expect(log(:transfer).can_continue?(:cleanup)).to be(true)
  end

  it 'rejects backwards and unknown transitions' do
    expect(log(:incremental).can_continue?(:base, sync_states: [])).to be(false)
    expect(log(:stage).can_continue?(:unknown)).to be(false)
  end

  it 'allows repeatable cleanup' do
    expect(log(:cleanup).can_continue?(:cleanup)).to be(true)
  end

  it 'allows configurable repeated sync states' do
    expect(log(:incremental).can_continue?(:incremental, sync_states: %i[incremental])).to be(true)
    expect(log(:base).can_continue?(:base, sync_states: %i[base incremental])).to be(true)
    expect(log(:base).can_continue?(:base, sync_states: %i[incremental])).to be(false)
  end

  it 'allows cancel before transfer and force cancel during transfer' do
    expect(log(:stage).can_cancel?).to be(true)
    expect(log(:base).can_cancel?).to be(true)
    expect(log(:incremental).can_cancel?).to be(true)
    expect(log(:transfer).can_cancel?).to be(false)
    expect(log(:transfer).can_cancel?(true)).to be(true)
    expect(log(:cleanup).can_cancel?(true)).to be(false)
  end
end
