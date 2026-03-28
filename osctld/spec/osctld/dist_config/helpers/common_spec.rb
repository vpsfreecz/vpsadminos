# frozen_string_literal: true

require 'osctld/dist_config/helpers/common'

RSpec.describe OsCtld::DistConfig::Helpers::Common do
  let(:helper_class) do
    Class.new do
      include OsCtld::DistConfig::Helpers::Common

      attr_reader :rootfs

      def initialize(rootfs)
        @rootfs = rootfs
      end
    end
  end

  let(:rootfs) { Dir.mktmpdir('dist-config-rootfs') }
  let(:helper) { helper_class.new(rootfs) }

  after do
    FileUtils.rm_rf(rootfs)
  end

  it 'treats missing files as writable and existing non-user-writable files as non-writable' do
    missing = File.join(rootfs, 'missing')
    present = File.join(rootfs, 'present')
    File.write(present, 'x')
    File.chmod(0o444, present)

    yielded = []

    expect(helper.writable?(missing) { |path| yielded << path }).to be(true)
    expect(helper.writable?(present)).to be(false)
    expect(yielded).to eq([missing])
  end

  it 'detects masked and enabled systemd services' do
    masked = File.join(rootfs, 'etc/systemd/system')
    FileUtils.mkdir_p(File.join(masked, 'multi-user.target.wants'))
    File.symlink(File::NULL, File.join(masked, 'svc.service'))
    File.write(File.join(masked, 'multi-user.target.wants', 'svc-enabled.service'), '')

    expect(helper.systemd_service_masked?('svc.service')).to be(true)
    expect(helper.systemd_service_enabled?('svc-enabled.service', 'multi-user.target')).to be(true)
    expect(helper.systemd_service_enabled?('missing.service', 'multi-user.target')).to be(false)
  end
end
