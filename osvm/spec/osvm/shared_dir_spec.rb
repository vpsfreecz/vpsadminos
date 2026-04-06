# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsVm::SharedDir do
  def build_machine_double(dir)
    instance_spy(OsVm::Machine).tap do |machine|
      allow(machine).to receive(:send).with(:tmpdir).and_return(dir)
      allow(machine).to receive(:all_succeed)
      allow(machine).to receive(:succeeds)
    end
  end

  it 'creates the expected directory structure on setup' do
    with_tmpdir do |dir|
      shared_dir = described_class.new(build_machine_double(dir))

      shared_dir.setup

      expect(File.directory?(shared_dir.host_path)).to be(true)
      expect(File.directory?(File.join(shared_dir.host_path, 'push'))).to be(true)
      expect(File.directory?(File.join(shared_dir.host_path, 'pull'))).to be(true)
    end
  end

  it 'mounts the shared directory inside the machine' do
    with_tmpdir do |dir|
      machine = build_machine_double(dir)
      shared_dir = described_class.new(machine)

      shared_dir.mount

      expect(machine).to have_received(:all_succeed).with(
        'mkdir -p "/run/osvm/shared-dir"',
        'mount -t virtiofs vmSharedDir "/run/osvm/shared-dir"'
      )
    end
  end

  it 'removes the host directory on destroy' do
    with_tmpdir do |dir|
      shared_dir = described_class.new(build_machine_double(dir))
      shared_dir.setup

      shared_dir.destroy

      expect(File.exist?(shared_dir.host_path)).to be(false)
    end
  end

  it 'pushes files through the host push directory and moves them in the machine' do
    with_tmpdir do |dir|
      machine = build_machine_double(dir)
      shared_dir = described_class.new(machine)
      shared_dir.setup
      src = File.join(dir, 'source.txt')
      File.write(src, 'hello')
      allow(shared_dir).to receive(:path_to_safe_name).and_return('safe-name')

      expect(shared_dir.push_file(src, '/etc/target.txt', preserve: true)).to eq('/etc/target.txt')
      expect(File.read(File.join(shared_dir.host_path, 'push', 'safe-name'))).to eq('hello')
      expect(machine).to have_received(:succeeds).with('mv "/run/osvm/shared-dir/push/safe-name" "/etc/target.txt"')
    end
  end

  it 'pulls files to the host pull directory and returns the host path' do
    with_tmpdir do |dir|
      machine = build_machine_double(dir)
      shared_dir = described_class.new(machine)
      shared_dir.setup
      allow(shared_dir).to receive(:path_to_safe_name).and_return('safe-name')

      expect(shared_dir.pull_file('/etc/target.txt', preserve: true)).to eq(
        File.join(shared_dir.host_path, 'pull', 'safe-name')
      )
      expect(machine).to have_received(:succeeds).with('cp -p "/etc/target.txt" "/run/osvm/shared-dir/pull/safe-name"')
    end
  end

  it 'sanitizes file names for transport' do
    with_tmpdir do |dir|
      shared_dir = described_class.new(build_machine_double(dir))

      safe_name = shared_dir.send(:path_to_safe_name, '/etc/system/config')

      expect(safe_name).to match(/\A[0-9a-f]{8}-etc--system--config\z/)
    end
  end
end
