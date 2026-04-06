# frozen_string_literal: true

require 'spec_helper'

RSpec.describe SvCtl::Service do
  let(:service) { described_class.new('sshd', 'default') }

  it 'detects whether the service exists' do
    with_svctl_paths do |paths|
      expect(service.exist?).to be(false)

      FileUtils.mkdir_p(File.join(paths[:services], 'sshd'))

      expect(service.exist?).to be(true)
    end
  end

  it 'detects whether the service is enabled' do
    with_svctl_paths do |paths|
      FileUtils.mkdir_p(File.join(paths[:services], 'sshd'))
      FileUtils.mkdir_p(File.join(paths[:runsvdir], 'default'))

      expect(service.enabled?).to be(false)

      File.symlink(
        File.join(paths[:services], 'sshd'),
        File.join(paths[:runsvdir], 'default', 'sshd')
      )

      expect(service.enabled?).to be(true)
    end
  end

  it 'enables the service by creating a symlink' do
    with_svctl_paths do |paths|
      FileUtils.mkdir_p(File.join(paths[:services], 'sshd'))
      FileUtils.mkdir_p(File.join(paths[:runsvdir], 'default'))

      service.enable

      expect(File.readlink(File.join(paths[:runsvdir], 'default', 'sshd'))).to eq(File.join(paths[:services], 'sshd'))
    end
  end

  it 'disables the service by removing the symlink' do
    with_svctl_paths do |paths|
      FileUtils.mkdir_p(File.join(paths[:services], 'sshd'))
      FileUtils.mkdir_p(File.join(paths[:runsvdir], 'default'))
      File.symlink(
        File.join(paths[:services], 'sshd'),
        File.join(paths[:runsvdir], 'default', 'sshd')
      )

      service.disable

      expect(File.exist?(File.join(paths[:runsvdir], 'default', 'sshd'))).to be(false)
    end
  end

  it 'lists runlevels where the service is enabled' do
    with_svctl_paths do |paths|
      FileUtils.mkdir_p(File.join(paths[:services], 'sshd'))
      FileUtils.mkdir_p(File.join(paths[:runsvdir], 'default'))
      FileUtils.mkdir_p(File.join(paths[:runsvdir], 'rescue'))
      File.symlink(
        File.join(paths[:services], 'sshd'),
        File.join(paths[:runsvdir], 'default', 'sshd')
      )

      allow(SvCtl).to receive(:runlevels).and_return(%w[default rescue])

      expect(service.runlevels).to eq(['default'])
    end
  end

  it 'sorts services by name' do
    first = described_class.new('alpha', 'default')
    second = described_class.new('omega', 'default')

    expect([second, first].sort).to eq([first, second])
  end
end
