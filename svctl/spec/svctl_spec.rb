# frozen_string_literal: true

require 'spec_helper'

RSpec.describe SvCtl do
  describe '.all_services' do
    it 'lists services from the service directory' do
      with_svctl_paths do |paths|
        %w[sshd nginx].each do |name|
          FileUtils.mkdir_p(File.join(paths[:services], name))
        end

        expect(described_class.all_services.map(&:name)).to contain_exactly('sshd', 'nginx')
      end
    end
  end

  describe '.runlevel_services' do
    it 'lists services from the selected runlevel' do
      with_svctl_paths do |paths|
        FileUtils.mkdir_p(File.join(paths[:runsvdir], 'default'))
        FileUtils.touch(File.join(paths[:runsvdir], 'default', 'sshd'))
        FileUtils.touch(File.join(paths[:runsvdir], 'default', 'nginx'))

        expect(described_class.runlevel_services('default').map(&:name)).to contain_exactly('sshd', 'nginx')
      end
    end
  end

  describe '.enable' do
    it 'does not raise when enabling an already enabled service' do
      with_svctl_paths do |paths|
        FileUtils.mkdir_p(File.join(paths[:services], 'sshd'))
        FileUtils.mkdir_p(File.join(paths[:runsvdir], 'default'))

        File.symlink(
          File.join(paths[:services], 'sshd'),
          File.join(paths[:runsvdir], 'default', 'sshd')
        )

        expect { described_class.enable('sshd', 'default') }.not_to raise_error
      end
    end
  end

  describe '.runlevels' do
    it 'ignores dot entries and reserved runlevel names' do
      with_svctl_paths do |paths|
        %w[default rescue current previous].each do |name|
          FileUtils.mkdir_p(File.join(paths[:runsvdir], name))
        end
        File.write(File.join(paths[:runsvdir], 'README'), 'note')

        expect(described_class.runlevels).to contain_exactly('default', 'rescue')
      end
    end
  end

  describe '.runlevel' do
    it 'returns the basename of the current runlevel symlink target' do
      with_svctl_paths do |paths|
        FileUtils.mkdir_p(File.join(paths[:runsvdir], 'default'))
        File.symlink(File.join(paths[:runsvdir], 'default'), File.join(paths[:runsvdir], 'current'))

        expect(described_class.runlevel).to eq('default')
      end
    end
  end

  describe '.switch' do
    it 'delegates to runsvchdir' do
      allow(described_class).to receive(:system)

      described_class.switch('default')

      expect(described_class).to have_received(:system).with('runsvchdir', 'default')
    end
  end

  describe 'protected service helpers' do
    it 'stores, returns, and removes protected services' do
      with_svctl_paths do
        described_class.protect('sshd')
        described_class.protect('nginx')
        described_class.protect('sshd')

        expect(described_class.protected_services).to eq(%w[sshd nginx])

        described_class.unprotect('sshd')

        expect(described_class.protected_services).to eq(['nginx'])
      end
    end
  end
end
