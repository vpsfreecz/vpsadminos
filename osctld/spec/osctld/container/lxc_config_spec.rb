# frozen_string_literal: true

# rubocop:disable RSpec/VerifiedDoubles

require 'osctld/container/lxc_config'
require 'osctld/assets/definition'
require 'osctld/erb_template'

RSpec.describe OsCtld::Container::LxcConfig do
  let(:run_conf) { double(distribution: 'alpine', version: '3.20') }
  let(:mounts) { double(all_entries: ['/mnt/data']) }
  let(:raw_configs) { double(lxc: 'lxc.include = common.conf') }
  let(:ct) do
    double(
      lxc_dir: '/var/lib/lxc/ct1',
      get_run_conf: run_conf,
      cgparams: ['memory.max = 1G'],
      prlimits: ['nofile=1024'],
      netifs: ['eth0'],
      mounts: mounts,
      raw_configs: raw_configs
    )
  end

  before do
    allow(OsCtld::ErbTemplate).to receive(:render_to)
  end

  it 'exports the config asset path' do
    definition = OsCtld::Assets::Definition::Scope.new

    described_class.new(ct).assets(definition)

    expect(definition.assets.map(&:path)).to eq(['/var/lib/lxc/ct1/config'])
  end

  it 'renders the LXC config and shares aliases with configure' do
    config = described_class.new(ct)

    config.configure_base
    config.configure_network

    expect(OsCtld::ErbTemplate).to have_received(:render_to).with(
      'ct/config',
      include(
        distribution: 'alpine',
        version: '3.20',
        ct: ct,
        cgparams: ['memory.max = 1G'],
        prlimits: ['nofile=1024'],
        netifs: ['eth0'],
        mounts: ['/mnt/data'],
        raw: 'lxc.include = common.conf'
      ),
      '/var/lib/lxc/ct1/config'
    ).twice
  end

  it 'duplicates itself for another container' do
    new_ct = double(lxc_dir: '/var/lib/lxc/ct2')

    copy = described_class.new(ct).dup(new_ct)

    expect(copy.config_path).to eq('/var/lib/lxc/ct2/config')
  end
end
# rubocop:enable RSpec/VerifiedDoubles
