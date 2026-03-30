# frozen_string_literal: true

require 'spec_helper'
require 'libosctl/cgroup'

RSpec.describe OsCtl::Lib::CGroup do
  let(:root_cgroup_procs) { File.join(described_class::FS, 'cgroup.procs') }

  around do |example|
    reset_module_ivars(described_class, :@version)
    example.run
    reset_module_ivars(described_class, :@version)
  end

  it 'detects cgroup v2 when cgroup.procs exists' do
    allow(File).to receive(:exist?).with(root_cgroup_procs).and_return(true)

    expect(described_class.version).to eq(2)
    expect(described_class).to be_v2
    expect(described_class).not_to be_v1
  end

  it 'detects cgroup v1 when cgroup.procs does not exist' do
    allow(File).to receive(:exist?).with(root_cgroup_procs).and_return(false)

    expect(described_class.version).to eq(1)
    expect(described_class).to be_v1
    expect(described_class).not_to be_v2
  end

  it 'reuses the cached version' do
    allow(File).to receive(:exist?).with(root_cgroup_procs).and_return(true)

    2.times { expect(described_class.version).to eq(2) }
    expect(File).to have_received(:exist?).with(root_cgroup_procs).once
  end
end
