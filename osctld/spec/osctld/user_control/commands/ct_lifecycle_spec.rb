# frozen_string_literal: true

# rubocop:disable RSpec/DescribeClass, RSpec/VerifiedDoubleReference, RSpec/VerifiedDoubles

require 'osctld/exceptions'
require 'osctld/user_control/command'
require 'osctld/user_control/commands/ct_post_stop'
require 'osctld/user_control/commands/ct_pre_start'

RSpec.describe 'authenticated container lifecycle callbacks' do
  let(:user) { instance_double('User') }
  let(:peer) { instance_double('OsCtld::ProcessIdentity') }
  let(:ct) { instance_double('Container') }
  let(:opts) { { id: 'ct1', pool: 'tank', run_id: 'stale' } }
  let(:rejection) { { status: false, message: 'stale container run' } }

  before do
    stub_const('OsCtld::DB', Module.new)
    stub_const('OsCtld::DB::Containers', double(find: ct))
    allow(OsCtld::BpfFs).to receive(:setup_ct)
    allow(OsCtld::BpfFs).to receive(:remove_ct)
  end

  it 'rejects stale pre-start before creating container BPF state' do
    command = OsCtld::UserControl::Commands::CtPreStart.new(user, opts, peer:)
    allow(command).to receive(:authenticate_lifecycle_callback)
      .with(ct)
      .and_return(rejection)

    expect(command.execute).to eq(rejection)
    expect(OsCtld::BpfFs).not_to have_received(:setup_ct)
  end

  it 'consumes authorization before effects and does not retry after failure' do
    command = OsCtld::UserControl::Commands::CtPreStart.new(user, opts, peer:)
    claimed = false
    allow(command).to receive(:authenticate_lifecycle_callback).with(ct).and_return(nil)
    allow(command).to receive(:claim_lifecycle_event) do
      if claimed
        { status: false, message: 'lifecycle event pre_start was already handled' }
      else
        claimed = true
        nil
      end
    end
    allow(ct).to receive(:starting).and_raise(RuntimeError, 'effect failed')

    expect { command.execute }.to raise_error(RuntimeError, 'effect failed')
    expect(command.execute).to eq(
      status: false,
      message: 'lifecycle event pre_start was already handled'
    )
    expect(ct).to have_received(:starting).once
  end

  it 'rejects stale post-stop before removing container BPF state' do
    command = OsCtld::UserControl::Commands::CtPostStop.new(user, opts, peer:)
    allow(command).to receive(:authenticate_lifecycle_callback)
      .with(ct)
      .and_return(rejection)

    expect(command.execute).to eq(rejection)
    expect(OsCtld::BpfFs).not_to have_received(:remove_ct)
  end

  it 'rejects an invalid stop target read from the authenticated peer' do
    command = OsCtld::UserControl::Commands::CtPostStop.new(
      user,
      opts.merge(target: 'stop'),
      peer:
    )
    allow(command).to receive(:authenticate_lifecycle_callback).with(ct).and_return(nil)
    allow(command).to receive(:claim_lifecycle_event)
    allow(peer).to receive(:environment_variable).with('LXC_TARGET').and_return('forged')

    expect(command.execute).to eq(
      status: false,
      message: 'invalid container stop target'
    )
    expect(command).not_to have_received(:claim_lifecycle_event)
    expect(OsCtld::BpfFs).not_to have_received(:remove_ct)
  end

  it 'ignores a caller-supplied stop target and derives it from the peer' do
    command = OsCtld::UserControl::Commands::CtPostStop.new(
      user,
      opts.merge(target: 'reboot'),
      peer:
    )
    claim_rejection = { status: false, message: 'derived stop target accepted' }
    allow(command).to receive(:authenticate_lifecycle_callback).with(ct).and_return(nil)
    allow(command).to receive(:claim_lifecycle_event)
      .with(ct, :post_stop, after: :wrapper_start)
      .and_return(claim_rejection)
    allow(peer).to receive(:environment_variable).with('LXC_TARGET').and_return('stop')

    expect(command.execute).to eq(claim_rejection)
    expect(peer).to have_received(:environment_variable).with('LXC_TARGET')
  end

  it 'fails closed when the authenticated peer environment cannot be read' do
    command = OsCtld::UserControl::Commands::CtPostStop.new(user, opts, peer:)
    allow(command).to receive(:authenticate_lifecycle_callback).with(ct).and_return(nil)
    allow(command).to receive(:claim_lifecycle_event)
    allow(peer).to receive(:environment_variable)
      .with('LXC_TARGET')
      .and_raise(IOError, 'peer exited')

    expect(command.execute).to eq(
      status: false,
      message: 'unable to resolve container stop target: peer exited'
    )
    expect(command).not_to have_received(:claim_lifecycle_event)
    expect(OsCtld::BpfFs).not_to have_received(:remove_ct)
  end

  it 'reboots and tears down exactly the authenticated run' do
    command = OsCtld::UserControl::Commands::CtPostStop.new(user, opts, peer:)
    run_conf = instance_double(
      'RunConfig',
      request_reboot: nil,
      wait_for_lifecycle_leases: nil
    )
    pool = instance_double('Pool', name: 'tank')

    allow(command).to receive(:authenticate_lifecycle_callback).with(ct).and_return(nil)
    allow(command).to receive(:authenticated_run_conf).and_return(run_conf)
    allow(command).to receive(:claim_lifecycle_event)
      .with(ct, :post_stop, after: :wrapper_start)
      .and_return(nil)
    allow(command).to receive(:log)
    allow(peer).to receive(:environment_variable).with('LXC_TARGET').and_return('reboot')
    allow(ct).to receive_messages(pool:, id: 'ct1')
    allow(ct).to receive(:stopped) do |expected_run, &block|
      expect(expected_run).to be(run_conf)
      block.call(true)
      true
    end
    stub_const('OsCtld::AppArmor', Class.new do
      def self.enabled? = false
    end)
    stub_const('OsCtld::Hook', Class.new do
      def self.run(*); end
    end)
    allow(OsCtld::Hook).to receive(:run)

    expect(command.execute).to eq(status: true, output: nil)
    expect(run_conf).to have_received(:request_reboot)
    expect(OsCtld::BpfFs).to have_received(:remove_ct).with('tank', 'ct1')
    expect(ct).to have_received(:stopped).with(run_conf)
    expect(OsCtld::Hook).to have_received(:run).with(ct, :post_stop)
  end

  it 'allows post-stop cleanup after registration even when pre-start was not reached' do
    command = OsCtld::UserControl::Commands::CtPostStop.new(
      user,
      opts.merge(target: 'stop'),
      peer:
    )
    claim_rejection = { status: false, message: 'stop after registration' }
    allow(command).to receive(:authenticate_lifecycle_callback).with(ct).and_return(nil)
    allow(peer).to receive(:environment_variable).with('LXC_TARGET').and_return('stop')
    allow(command).to receive(:claim_lifecycle_event)
      .with(ct, :post_stop, after: :wrapper_start)
      .and_return(claim_rejection)

    expect(command.execute).to eq(claim_rejection)
  end
end

# rubocop:enable RSpec/DescribeClass, RSpec/VerifiedDoubleReference, RSpec/VerifiedDoubles
