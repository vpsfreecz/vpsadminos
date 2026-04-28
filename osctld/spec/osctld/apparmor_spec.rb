# frozen_string_literal: true

# rubocop:disable RSpec/VerifiedDoubles

require 'osctld/apparmor'
require 'osctld/assets/definition'
require 'osctld/assets/directory'

RSpec.describe OsCtld::AppArmor do
  let(:pool) { double(apparmor_dir: '/run/osctl/pool.tank/apparmor', name: 'tank') }

  before do
    described_class.instance_variable_set(:@enabled, nil)
    stub_const(
      'OsCtld::Daemon',
      Class.new do
        def self.get; end
      end
    )
  end

  it 'detects whether AppArmor is enabled' do
    daemon = double(config: double(apparmor_paths: ['/etc/apparmor.d']))
    allow(OsCtld::Daemon).to receive(:get).and_return(daemon)
    allow(Dir).to receive(:exist?).with(described_class::SECURITYFS_APPARMOR).and_return(true)
    allow(File).to receive(:read).with(described_class::APPARMOR_ENABLED).and_return("Y\n")

    expect(described_class.enabled?).to be(true)
  end

  it 'detects LSM namespace support when securityfs is restricted' do
    daemon = double(config: double(apparmor_paths: ['/etc/apparmor.d']))
    allow(OsCtld::Daemon).to receive(:get).and_return(daemon)
    allow(Dir).to receive(:exist?).with(described_class::SECURITYFS_APPARMOR).and_return(false)
    allow(File).to receive(:exist?).with('/proc/self/ns/lsm').and_return(true)
    allow(File).to receive(:read).with(described_class::APPARMOR_ENABLED).and_return("Y\n")

    expect(described_class.enabled?).to be(true)
    expect(described_class.lsm_namespace_supported?).to be(true)
  end

  it 'sets up shared AppArmor files with configured parser include paths' do
    with_tmpdir do |dir|
      apparmor_dir = File.join(dir, 'apparmor')
      daemon = double(config: double(apparmor_paths: ['/etc/apparmor.d', '/etc/lxc/apparmor.d']))

      stub_const('OsCtld::AppArmor::PATHS', [apparmor_dir].freeze)
      allow(OsCtld::Daemon).to receive(:get).and_return(daemon)
      allow(OsCtld::ErbTemplate).to receive(:render_to) do |_template, _vars, path|
        File.write(path, "mount fstype=proc,\n")
      end

      expect { described_class.setup }.not_to raise_error
      expect(described_class.paths).to eq([apparmor_dir, '/etc/apparmor.d', '/etc/lxc/apparmor.d'])
      expect(File).to exist(File.join(apparmor_dir, 'osctl', 'features', 'nesting'))
    end
  end

  it 'exposes profile and cache directory assets separately' do
    definition = OsCtld::Assets::Definition::Scope.new

    described_class.assets(definition, pool)

    expect(definition.assets.map(&:path)).to eq([
                                                  '/run/osctl/pool.tank/apparmor/profiles',
                                                  '/run/osctl/pool.tank/apparmor/cache'
                                                ])
  end

  it 'leaves LXC label handling to the kernel LSM namespace backend when supported' do
    ct = double(pool:, id: 'ct1')
    apparmor = described_class.new(ct)

    allow(described_class).to receive(:lsm_namespace_supported?).and_return(true)

    expect(apparmor.lxc_profile_name).to eq('unchanged')
  end

  it 'uses the legacy stacked profile name when LSM namespaces are unavailable' do
    ct = double(pool:, id: 'ct1')
    apparmor = described_class.new(ct)

    allow(described_class).to receive(:lsm_namespace_supported?).and_return(false)

    expect(apparmor.lxc_profile_name).to eq('ct-tank-ct1//&:lxc-ct-tank-ct1:')
  end
end
# rubocop:enable RSpec/VerifiedDoubles
