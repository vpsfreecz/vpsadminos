# frozen_string_literal: true

# rubocop:disable RSpec/MultipleMemoizedHelpers, RSpec/ReceiveMessages
# rubocop:disable RSpec/SubjectStub, RSpec/VerifiedDoubleReference, RSpec/VerifiedDoubles

$:.unshift(File.expand_path('../../../fixtures/ruby_load_path', __dir__))

require 'osctld/user_control/commands/ct_netns_setup'

RSpec.describe OsCtld::UserControl::Commands::CtNetnsSetup do
  subject(:command) { described_class.new(user, opts, peer:) }

  let(:user) { instance_double('User') }
  let(:peer) { instance_double('OsCtld::ProcessIdentity') }
  let(:lifecycle_identity) { instance_double(OsCtld::ProcessIdentity) }
  let(:run_conf) do
    instance_double(
      'RunConfig',
      init_pid: 1234,
      lifecycle_identity:
    )
  end
  let(:ct) do
    instance_double(
      'Container',
      user:,
      run_conf:,
      refresh_init_pid: nil,
      base_cgroup_path: '/osctl/pool.tank/ct.ct1'
    )
  end
  let(:init_identity) do
    instance_double(
      OsCtld::ProcessIdentity,
      in_cgroup_subtree?: true,
      descendant_of?: true,
      close: nil
    )
  end
  let(:net_config) { instance_double(OsCtld::NetConfig, export: [{ name: 'eth0' }]) }
  let(:opts) do
    {
      id: 'ct1',
      pool: 'tank',
      run_id: 'current',
      init_pid: 1,
      net_config: [{ name: 'attacker-controlled' }]
    }
  end

  before do
    stub_const('OsCtld::DB', Module.new)
    stub_const('OsCtld::DB::Containers', double(find: ct))
    allow(command).to receive(:authenticate_run_callback).with(ct).and_return(nil)
    allow(command).to receive(:authenticated_run_conf).and_return(run_conf)
    allow(command).to receive(:claim_lifecycle_event)
      .with(
        ct,
        :netns_setup,
        after: :wrapper_start,
        lifecycle: false
      )
      .and_return(nil)
    allow(command).to receive(:setup_netns).and_return(status: true, output: nil)
    allow(OsCtld::ContainerControl::Commands::State).to receive(:run!)
      .with(ct)
      .and_return(Struct.new(:init_pid).new(1234))
    allow(OsCtld::ProcessIdentity).to receive(:new)
      .with(1234, namespaces: [:net])
      .and_return(init_identity)
    allow(OsCtld::NetConfig).to receive(:create).with(ct).and_return(net_config)
  end

  it 'derives the init identity and network configuration server-side' do
    ret = command.execute

    expect(ret).to eq(status: true, output: nil)
    expect(command).to have_received(:setup_netns).with(
      init_identity,
      [{ name: 'eth0' }]
    )
    expect(init_identity).to have_received(:in_cgroup_subtree?).with(
      '/osctl/pool.tank/ct.ct1'
    )
    expect(init_identity).to have_received(:descendant_of?).with(lifecycle_identity)
    expect(command).to have_received(:claim_lifecycle_event).with(
      ct,
      :netns_setup,
      after: :wrapper_start,
      lifecycle: false
    )
    expect(init_identity).to have_received(:close)
  end

  it 'rejects replay before applying network configuration again' do
    replay = { status: false, message: 'lifecycle event netns_setup was already handled' }
    allow(command).to receive(:claim_lifecycle_event).and_return(replay)

    expect(command.execute).to eq(replay)
    expect(command).not_to have_received(:setup_netns)
    expect(init_identity).to have_received(:close)
  end

  it 'rejects an init process outside the container cgroup' do
    allow(init_identity).to receive(:in_cgroup_subtree?).and_return(false)

    ret = command.execute

    expect(ret[:status]).to be(false)
    expect(ret[:message]).to include('outside its cgroup')
    expect(command).not_to have_received(:setup_netns)
    expect(init_identity).to have_received(:close)
  end

  it 'rejects an init process outside the active lifecycle' do
    allow(init_identity).to receive(:descendant_of?).and_return(false)

    ret = command.execute

    expect(ret[:status]).to be(false)
    expect(ret[:message]).to include('outside its lifecycle')
    expect(command).not_to have_received(:setup_netns)
    expect(init_identity).to have_received(:close)
  end
end

# rubocop:enable RSpec/MultipleMemoizedHelpers, RSpec/ReceiveMessages
# rubocop:enable RSpec/SubjectStub, RSpec/VerifiedDoubleReference, RSpec/VerifiedDoubles
