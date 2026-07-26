# frozen_string_literal: true

require 'osctld/command'
require 'osctld/commands/container/attachment_activate'
require 'osctld/commands/container/attachment_handoff'
require 'osctld/commands/container/attachment_finish'
require 'osctld/container/lifecycle'

RSpec.describe OsCtld::Commands::Container::AttachmentActivate do
  def command(klass, opts)
    socket = instance_double(
      Socket,
      getsockopt: [Process.pid, Process.uid, Process.gid].pack('iii')
    )
    handler = Struct.new(:socket).new(socket)
    klass.new(opts, handler:)
  end

  before do
    db = stub_const('OsCtld::DB::Containers', Class.new do
      def self.find(_id, _pool); end
    end)
    allow(db).to receive(:find).with('ct1', 'tank').and_return(ct)
  end

  let(:ct) do
    Struct.new(:lifecycle, :run_conf, keyword_init: true) do
      def get_past_run_conf
        nil
      end
    end.new(lifecycle:)
  end
  let(:lifecycle) do
    instance_spy(
      OsCtld::Container::Lifecycle,
      handoff_attachment: true,
      handoff_attachment_child: true,
      finish_external_attachment: [true, false]
    )
  end
  let(:base_opts) do
    {
      pool: 'tank',
      id: 'ct1',
      run_id: 'run-1',
      process_id: 'process-1'
    }
  end

  it 'activates the wrapper reservation from its exact peer process' do
    ret = command(
      described_class,
      base_opts
    ).execute

    expect(ret).to eq(status: true, output: nil)
    expect(lifecycle).to have_received(:handoff_attachment).with(
      'run-1',
      'process-1',
      pid: Process.pid
    )
  end

  it 'hands the reservation to the gated command child' do
    ret = command(
      OsCtld::Commands::Container::AttachmentHandoff,
      base_opts.merge(pid: 4321)
    ).execute

    expect(ret).to eq(status: true, output: nil)
    expect(lifecycle).to have_received(:handoff_attachment_child).with(
      'run-1',
      'process-1',
      pid: Process.pid,
      child_pid: 4321
    )
  end

  it 'finishes the child reservation from its exact supervisor' do
    ret = command(
      OsCtld::Commands::Container::AttachmentFinish,
      base_opts
    ).execute

    expect(ret).to eq(status: true, output: nil)
    expect(lifecycle).to have_received(:finish_external_attachment).with(
      'run-1',
      'process-1',
      pid: Process.pid
    )
  end
end
