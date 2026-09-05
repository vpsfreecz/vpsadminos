# frozen_string_literal: true

# rubocop:disable RSpec/SubjectStub, RSpec/VerifiedDoubleReference, RSpec/VerifiedDoubles

require 'stringio'

module OsCtld
  module UserControl
    module Commands; end

    unless const_defined?(:Command)
      class Command
        def self.register(*); end
      end
    end
  end
end

require 'osctld/cgroup'
require 'osctld/process_identity'
require 'osctld/user_control/commands/ct_wrapper_start'

RSpec.describe OsCtld::UserControl::Commands::CtWrapperStart do
  subject(:command) { described_class.new(user, opts, peer:) }

  let(:user) { instance_double('User') }
  let(:peer) { instance_double(OsCtld::ProcessIdentity, pid: 4321) }
  let(:run_conf) { instance_double('RunConfig', register_lifecycle: nil) }
  let(:ct) { instance_double('Container', run_conf:) }
  let(:opts) do
    {
      id: 'ct1',
      pool: 'tank',
      run_id: 'run-1',
      lifecycle_start_token: 'start-token'
    }
  end

  before do
    stub_const('OsCtld::DB', Module.new)
    stub_const('OsCtld::DB::Containers', double(find: ct))
    allow(command).to receive(:authenticate_run_callback).with(ct).and_return(nil)
    allow(command).to receive(:with_authenticated_run)
      .with(ct)
      .and_yield(run_conf)
      .and_return(nil)
    allow(command).to receive(:peer_in_container_cgroup?).with(ct).and_return(true)
    allow(command).to receive(:log)
    allow(peer).to receive(:open_proc_file)
      .with('oom_score_adj', 'w')
      .and_yield(StringIO.new)
    allow(OsCtld::CGroup).to receive(:mkpath_all)
  end

  it 'registers a wrapper which already moved itself into the container cgroup' do
    expect(command.execute).to eq(status: true, output: nil)
    expect(OsCtld::CGroup).not_to have_received(:mkpath_all)
    expect(run_conf).to have_received(:register_lifecycle).with(
      peer,
      token: 'start-token'
    )
  end

  it 'registers and consumes the lifecycle capability before resetting OOM policy' do
    expect(command.execute).to eq(status: true, output: nil)
    expect(run_conf).to have_received(:register_lifecycle)
      .with(peer, token: 'start-token')
      .ordered
    expect(peer).to have_received(:open_proc_file)
      .with('oom_score_adj', 'w')
      .ordered
  end

  [
    ['an invalid capability', 'invalid lifecycle start capability'],
    ['a replayed capability', 'invalid lifecycle start capability'],
    ['an already-registered lifecycle', 'container lifecycle is already registered']
  ].each do |label, message|
    it "does not reset OOM policy for #{label}" do
      allow(run_conf).to receive(:register_lifecycle)
        .and_raise(OsCtld::Container::RunConfiguration::LifecycleError, message)

      expect(command.execute).to eq(status: false, message:)
      expect(peer).not_to have_received(:open_proc_file)
      expect(run_conf).to have_received(:register_lifecycle).once
    end
  end

  it 'keeps a successful registration consumed when the OOM reset fails' do
    allow(peer).to receive(:open_proc_file)
      .with('oom_score_adj', 'w')
      .and_raise(Errno::EIO, '/proc/4321/oom_score_adj')
    allow(command).to receive(:with_authenticated_run).with(ct) do |&block|
      block.call(run_conf)
      nil
    rescue SystemCallError, IOError, ArgumentError, TypeError
      { status: false, message: 'unable to authenticate callback' }
    end

    expect(command.execute).to eq(
      status: false,
      message: 'unable to authenticate callback'
    )
    expect(run_conf).to have_received(:register_lifecycle).once.with(
      peer,
      token: 'start-token'
    )
    expect(peer).to have_received(:open_proc_file).once

    allow(run_conf).to receive(:register_lifecycle)
      .and_raise(
        OsCtld::Container::RunConfiguration::LifecycleError,
        'invalid lifecycle start capability'
      )

    expect(command.execute).to eq(
      status: false,
      message: 'invalid lifecycle start capability'
    )
    expect(peer).to have_received(:open_proc_file).once
  end

  it 'rejects a wrapper which did not complete self-migration' do
    allow(command).to receive(:peer_in_container_cgroup?).with(ct).and_return(false)

    expect(command.execute).to eq(
      status: false,
      message: 'lifecycle process is not in the container cgroup'
    )
    expect(peer).not_to have_received(:open_proc_file)
    expect(run_conf).not_to have_received(:register_lifecycle)
    expect(command).not_to have_received(:with_authenticated_run)
  end

  it 'rejects a wrapper without a lifecycle capability' do
    opts.delete(:lifecycle_start_token)

    expect(command.execute).to eq(
      status: false,
      message: 'missing lifecycle start capability'
    )
    expect(peer).not_to have_received(:open_proc_file)
    expect(run_conf).not_to have_received(:register_lifecycle)
    expect(command).not_to have_received(:with_authenticated_run)
  end
end

# rubocop:enable RSpec/SubjectStub, RSpec/VerifiedDoubleReference, RSpec/VerifiedDoubles
