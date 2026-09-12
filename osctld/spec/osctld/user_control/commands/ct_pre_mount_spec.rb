# frozen_string_literal: true

require 'osctld/container/nfs_cancellation'
require 'osctld/user_control/command'
require 'osctld/user_control/commands/ct_pre_mount'

RSpec.describe OsCtld::UserControl::Commands::CtPreMount do
  subject(:command) { described_class.new(user, id: 'ct1', pool: 'tank', client_pid: 123) }

  let(:user) { Object.new }
  let(:cancellation) { instance_double(OsCtld::Container::NfsCancellation, capture: nil) }
  let(:run_conf) { Struct.new(:nfs_cancellation).new(cancellation) }
  let(:ct) { Struct.new(:user, :get_run_conf, :map_mode).new(user, run_conf, 'zfs') }

  before do
    stub_const('OsCtld::DB::Containers', Class.new do
      def self.find(_id, _pool); end
    end)
    allow(OsCtld::DB::Containers).to receive(:find).with('ct1', 'tank').and_return(ct)
    stub_const('OsCtld::Hook', Class.new do
      def self.run(*_args, **_kwargs); end
    end)
    allow(OsCtld::Hook).to receive(:run)
  end

  it 'captures the authenticated peer before running mount hooks' do
    calls = []
    allow(cancellation).to receive(:capture) { |pid| calls << [:capture, pid] }
    allow(OsCtld::Hook).to receive(:run) { |*args, **kwargs| calls << [:hook, args, kwargs] }

    command.execute
    expect(cancellation).to have_received(:capture).with(123, trusted: true)
    expect(calls).to eq([
                          [:capture, 123],
                          [:hook, [ct, :pre_mount], { rootfs_mount: nil, ns_pid: 123 }]
                        ])
  end

  it 'does not capture namespaces of another user' do
    ct.user = Object.new
    command.execute

    expect(cancellation).not_to have_received(:capture)
    expect(OsCtld::Hook).not_to have_received(:run)
  end
end
