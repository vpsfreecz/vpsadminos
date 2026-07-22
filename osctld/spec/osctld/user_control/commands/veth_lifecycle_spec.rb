# frozen_string_literal: true

# rubocop:disable RSpec/DescribeClass, RSpec/VerifiedDoubleReference

require 'osctld/utils/ip'
require 'osctld/net_interface/veth'
require 'osctld/user_control/command'
require 'osctld/user_control/commands/veth_down'
require 'osctld/user_control/commands/veth_up'

RSpec.describe 'authenticated container veth callbacks' do
  let(:user) { instance_double('User') }
  let(:peer) { instance_double('OsCtld::ProcessIdentity') }
  let(:opts) { { id: 'ct1', pool: 'tank', run_id: 'current' } }

  before do
    stub_const('OsCtld::DB', Module.new)
    stub_const('OsCtld::DB::Containers', double)
  end

  it 'validates a veth identity before consuming the up event' do
    netif = OsCtld::NetInterface::Veth.allocate
    allow(netif).to receive_messages(name: 'eth0', enable: true)
    ct = instance_double('Container', netifs: { 'eth0' => netif })
    command = OsCtld::UserControl::Commands::VethUp.new(
      user,
      opts.merge(interface: 'eth0', veth: 'foreign0'),
      peer:
    )

    allow(OsCtld::DB::Containers).to receive(:find).and_return(ct)
    allow(command).to receive(:authenticate_lifecycle_callback).with(ct).and_return(nil)
    allow(command).to receive(:claim_lifecycle_event)
    allow(netif).to receive(:validate_up_callback)
      .with('foreign0')
      .and_raise(
        OsCtld::NetInterface::Veth::InvalidHostLink,
        'host interface "foreign0" does not belong to the container'
      )

    expect(command.execute).to eq(
      status: false,
      message: 'host interface "foreign0" does not belong to the container'
    )
    expect(command).not_to have_received(:claim_lifecycle_event)
  end

  it 'orders a veth-down callback after the matching veth-up callback' do
    netif = OsCtld::NetInterface::Veth.allocate
    allow(netif).to receive(:name).and_return('eth0')
    allow(netif).to receive(:validate_down_callback)
      .with('veth0')
      .and_return(['veth0', 10, 10])
    ct = instance_double('Container', netifs: { 'eth0' => netif })
    command = OsCtld::UserControl::Commands::VethDown.new(
      user,
      opts.merge(interface: 'eth0', veth: 'veth0'),
      peer:
    )
    claim_rejection = { status: false, message: 'ordered stop' }

    allow(OsCtld::DB::Containers).to receive(:find).and_return(ct)
    allow(command).to receive(:authenticate_lifecycle_callback).with(ct).and_return(nil)
    allow(command).to receive(:claim_lifecycle_event)
      .with(ct, 'veth_down:eth0', after: 'veth_up:eth0')
      .and_return(claim_rejection)

    expect(command.execute).to eq(claim_rejection)
  end
end
# rubocop:enable RSpec/DescribeClass, RSpec/VerifiedDoubleReference
