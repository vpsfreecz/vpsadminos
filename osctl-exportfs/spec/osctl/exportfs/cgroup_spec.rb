# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsCtl::ExportFS::CGroup do
  it 'builds v1 and v2 cgroup paths' do
    allow(OsCtl::Lib::CGroup).to receive(:v2?).and_return(false)
    expect(described_class.new('grp').send(:abs_cgroup_path, 'payload')).to eq(
      '/sys/fs/cgroup/systemd/grp/payload'
    )

    allow(OsCtl::Lib::CGroup).to receive(:v2?).and_return(true)
    expect(described_class.new('grp').send(:abs_cgroup_path, 'payload')).to eq(
      '/sys/fs/cgroup/grp/payload'
    )
  end

  it 'creates, destroys, and enters cgroups' do
    with_tmpdir do |tmpdir|
      stub_const('OsCtl::ExportFS::CGroup::FS', tmpdir)
      allow(OsCtl::Lib::CGroup).to receive(:v2?).and_return(true)

      cg = described_class.new('grp')
      cg.create('payload')
      expect(Dir.exist?(File.join(tmpdir, 'grp', 'payload'))).to be(true)

      cg.enter('payload')
      expect(File.read(File.join(tmpdir, 'grp', 'payload', 'cgroup.procs'))).to eq(Process.pid.to_s)

      File.unlink(File.join(tmpdir, 'grp', 'payload', 'cgroup.procs'))
      cg.destroy('payload')
      expect(Dir.exist?(File.join(tmpdir, 'grp', 'payload'))).to be(false)
    end
  end

  it 'counts only successfully signalled processes in kill_all' do
    with_tmpdir do |tmpdir|
      stub_const('OsCtl::ExportFS::CGroup::FS', tmpdir)
      allow(OsCtl::Lib::CGroup).to receive(:v2?).and_return(true)

      path = File.join(tmpdir, 'grp', 'payload')
      FileUtils.mkdir_p(path)
      File.write(File.join(path, 'cgroup.procs'), "100\n200\n")

      cg = described_class.new('grp')
      allow(Process).to receive(:kill).with('TERM', 100).and_return(1)
      allow(Process).to receive(:kill).with('TERM', 200).and_raise(Errno::ESRCH)

      expect(cg.kill_all('payload')).to eq(1)
    end
  end

  it 'loops until the cgroup is empty and sleeps only when processes were killed' do
    cg = described_class.new('grp')
    allow(cg).to receive(:kill_all).with('payload').and_return(2, 1, 0)
    allow(cg).to receive(:sleep)

    cg.kill_all_until_empty('payload')

    expect(cg).to have_received(:sleep).with(3).twice
  end
end
