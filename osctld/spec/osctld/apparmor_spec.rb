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
    allow(Dir).to receive(:exist?).with('/sys/kernel/security/apparmor').and_return(true)
    allow(File).to receive(:read).with('/sys/module/apparmor/parameters/enabled').and_return("Y\n")

    expect(described_class.enabled?).to be(true)
  end

  it 'exposes profile and cache directory assets separately' do
    definition = OsCtld::Assets::Definition::Scope.new

    described_class.assets(definition, pool)

    expect(definition.assets.map(&:path)).to eq([
                                                  '/run/osctl/pool.tank/apparmor/profiles',
                                                  '/run/osctl/pool.tank/apparmor/cache'
                                                ])
  end
end
# rubocop:enable RSpec/VerifiedDoubles
