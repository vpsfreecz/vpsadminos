# frozen_string_literal: true

require 'osctld/exceptions'
require 'osctld/user_control/command'
require 'osctld/user_control/commands/ct_on_start'

RSpec.describe OsCtld::UserControl::Commands::CtOnStart do
  subject(:command) { described_class.new(user, opts) }

  let(:user) { instance_double('User') }
  let(:run_conf) { instance_double('RunConfig', init_pid: 1234) }
  let(:init_net_ns) { instance_double(File, 'init_net_ns') }
  let(:init_pid_ns) { instance_double(File, 'init_pid_ns') }
  let(:init_identity) do
    instance_double(
      OsCtld::ProcessIdentity,
      pid: 1234,
      alive?: true,
      close: nil
    )
  end
  let(:ct) do
    instance_double(
      'Container',
      id: 'ct1',
      user:,
      run_conf:,
      can_dist_configure_network?: true,
      refresh_init_pid: 5678
    )
  end
  let(:opts) { { id: 'ct1', pool: 'tank', init_pid: '9999' } }
  let(:exported_net_config) do
    [{ name: 'eth0', ips: [{ address: '192.0.2.10' }], routes: [] }]
  end
  let(:net_config) { instance_double(OsCtld::NetConfig) }

  before do
    stub_const('OsCtld::DB', Module.new)
    stub_const('OsCtld::DB::Containers', double(find: ct))
    stub_const(
      'OsCtld::DistConfig',
      Module.new do
        def self.run(*); end
      end
    )

    stub_const(
      'OsCtld::CGroup',
      Module.new do
        def self.v2?
          false
        end
      end
    )

    stub_const(
      'OsCtld::Hook',
      Module.new do
        def self.run(*); end
      end
    )

    allow(OsCtld::DistConfig).to receive(:run)
    allow(OsCtld::Hook).to receive(:run)
    allow(init_identity).to receive(:namespace).with(:net).and_return(init_net_ns)
    allow(init_identity).to receive(:namespace).with(:pid).and_return(init_pid_ns)
    allow(OsCtld::ProcessIdentity).to receive(:new)
      .with(1234, namespaces: %i[net pid])
      .and_return(init_identity)
    allow(OsCtld::NetConfig).to receive(:create).with(ct).and_return(net_config)
    allow(net_config).to receive(:export).with(configured_only: true).and_return(exported_net_config)
    allow(command).to receive(:fork_static_network_setup)
  end

  it 'ignores the hook PID and applies static config using the server-held init identity' do
    ret = command.execute

    expect(ret).to eq(status: true, output: nil)
    expect(OsCtld::DistConfig).to have_received(:run).with(run_conf, :start)
    expect(command).to have_received(:fork_static_network_setup).with(
      init_identity,
      exported_net_config
    )
  end

  it 'refreshes a missing server-held runtime configuration init PID' do
    refreshed_identity = instance_double(OsCtld::ProcessIdentity, close: nil)
    allow(run_conf).to receive(:init_pid).and_return(nil)
    allow(OsCtld::ProcessIdentity).to receive(:new)
      .with(5678, namespaces: %i[net pid])
      .and_return(refreshed_identity)

    command.execute

    expect(command).to have_received(:fork_static_network_setup).with(
      refreshed_identity,
      exported_net_config
    )
  end

  it 'skips static netns setup when no interfaces need host-applied config' do
    allow(net_config).to receive(:export).with(configured_only: true).and_return([])

    ret = command.execute

    expect(ret).to eq(status: true, output: nil)
    expect(command).not_to have_received(:fork_static_network_setup)
    expect(OsCtld::Hook).to have_received(:run).with(ct, :on_start)
  end

  it 'returns a command error when static network setup fails' do
    allow(command)
      .to receive(:fork_static_network_setup)
      .and_raise(described_class::NetworkSetupFailed, 'network setup failed: boom')

    ret = command.execute

    expect(ret).to eq(status: false, message: 'network setup failed: boom')
  end
end
