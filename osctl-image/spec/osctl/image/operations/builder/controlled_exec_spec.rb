# frozen_string_literal: true

require 'spec_helper'
require 'shellwords'

RSpec.describe OsCtl::Image::Operations::Builder::ControlledExec do
  subject(:op) do
    described_class.new(
      builder,
      ['/path/with space/tool', 'arg with space'],
      id: 'abcd',
      client:,
      env: { 'LANG' => 'C' }
    )
  end

  let(:builder) do
    instance_double(
      OsCtl::Image::Builder,
      ctid: 'builder-1',
      attrs: { group_path: 'group/path' }
    )
  end
  let(:client) { instance_double(OsCtl::Image::OsCtldClient) }

  before do
    allow(OsCtl::Lib::CGroup).to receive(:v2?).and_return(true)
  end

  it 'renders the startup script with the expected cgroup path, env and shell escaping' do
    expect(op.send(:start_script)).to include('cgroup="/sys/fs/cgroup/osctl-image.exec.abcd"')
    expect(op.send(:start_script)).to include(
      "exec #{Shellwords.join(['env', 'LANG=C', '/path/with space/tool', 'arg with space'])}"
    )
  end

  it 'forwards the injected client to RunscriptFromString' do
    allow(OsCtl::Image::Operations::Builder::RunscriptFromString).to receive(:run).and_return(0)
    allow(Dir).to receive(:exist?).and_return(false)

    op.execute

    expect(OsCtl::Image::Operations::Builder::RunscriptFromString).to have_received(:run).with(
      builder,
      kind_of(String),
      client:
    )
  end

  it 'returns 1 when the nested runscript does not report a status' do
    allow(OsCtl::Image::Operations::Builder::RunscriptFromString).to receive(:run).and_return(nil)
    allow(Dir).to receive(:exist?).and_return(false)

    expect(op.execute).to eq(1)
  end

  it 'does nothing when the cgroup directory is absent' do
    allow(Dir).to receive(:exist?).and_return(false)
    allow(Process).to receive(:kill)

    op.send(:clear_cgroup)

    expect(Process).not_to have_received(:kill)
  end

  it 'kills all pids listed in cgroup.procs' do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'cgroup.procs'), "101\n202\n")
      allow(Process).to receive(:kill)

      expect(op.send(:kill_all, dir, 'TERM')).to be(true)
      expect(Process).to have_received(:kill).with('TERM', 101)
      expect(Process).to have_received(:kill).with('TERM', 202)
    end
  end
end
