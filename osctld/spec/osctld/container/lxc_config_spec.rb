# frozen_string_literal: true

# rubocop:disable RSpec/VerifiedDoubles

require 'osctld/container/lxc_config'
require 'osctld/container/run_id'
require 'osctld/assets/definition'
require 'osctld/erb_template'

RSpec.describe OsCtld::Container::LxcConfig do
  let(:run_id) do
    OsCtld::Container::RunId.new(
      pool_name: 'tank',
      container_id: 'ct1',
      key: 'a' * 32
    )
  end
  let(:run_conf) do
    double(
      distribution: 'alpine',
      version: '3.20',
      rootfs: '/tank/ct/ct1/private',
      run_id:
    )
  end
  let(:mounts) { double(all_entries: ['/mnt/data']) }
  let(:raw_configs) { double(lxc: 'lxc.environment = RAW_CONFIG=1') }
  let(:ct) do
    double(
      lxc_dir: '/var/lib/lxc/ct1',
      get_run_conf: run_conf,
      cgparams: ['memory.max = 1G'],
      prlimits: ['nofile=1024'],
      netifs: ['eth0'],
      mounts: mounts,
      raw_configs: raw_configs,
      lifecycle: double(active_run_id: run_id)
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
        run_conf:,
        rootfs: '/tank/ct/ct1/private',
        cgparams: ['memory.max = 1G'],
        prlimits: ['nofile=1024'],
        netifs: ['eth0'],
        mounts: ['/mnt/data'],
        raw: 'lxc.environment = RAW_CONFIG=1'
      ),
      '/var/lib/lxc/ct1/config'
    ).twice
    expect(OsCtld::ErbTemplate).to have_received(:render_to).with(
      'ct/config',
      include(run_conf:),
      "/var/lib/lxc/ct1/config.#{run_id.key}"
    ).twice
  end

  it 'marks the container as errored when the rootfs path is unavailable' do
    unavailable_run_conf = double(distribution: 'alpine', version: '3.20', rootfs: nil)
    unavailable_ct = double(
      lxc_dir: '/var/lib/lxc/ct1',
      get_run_conf: unavailable_run_conf,
      state: :stopped
    )
    config = described_class.new(unavailable_ct)

    allow(unavailable_ct).to receive(:state=)
    allow(config).to receive(:log)

    expect(config.configure).to be(false)
    expect(unavailable_ct).to have_received(:state=).with(:error)
    expect(OsCtld::ErbTemplate).not_to have_received(:render_to)
    expect(config).to have_received(:log).with(
      :warn,
      unavailable_ct,
      'Unable to generate LXC config: rootfs path is not available'
    )
  end

  it 'does not mark staged containers as errored when the rootfs path is unavailable' do
    unavailable_run_conf = double(distribution: 'alpine', version: '3.20', rootfs: nil)
    staged_ct = double(
      lxc_dir: '/var/lib/lxc/ct1',
      get_run_conf: unavailable_run_conf,
      state: :staged
    )
    config = described_class.new(staged_ct)

    allow(staged_ct).to receive(:state=)
    allow(config).to receive(:log)

    expect(config.configure).to be(false)
    expect(staged_ct).not_to have_received(:state=)
    expect(OsCtld::ErbTemplate).not_to have_received(:render_to)
    expect(config).to have_received(:log).with(
      :warn,
      staged_ct,
      'Skipping LXC config generation: rootfs path is not available'
    )
  end

  it 'duplicates itself for another container' do
    new_ct = double(lxc_dir: '/var/lib/lxc/ct2')

    copy = described_class.new(ct).dup(new_ct)

    expect(copy.config_path).to eq('/var/lib/lxc/ct2/config')
  end

  it 'rejects raw configuration that overrides lifecycle hooks or cgroups' do
    allow(raw_configs).to receive(:lxc).and_return(
      "lxc.cgroup.dir.monitor = custom\n"
    )

    expect { described_class.new(ct).configure }
      .to raise_error(OsCtld::ConfigError, /managed by osctld/)
  end

  it 'rejects raw CPU bandwidth on LXC-owned payload cgroups' do
    %w[
      lxc.cgroup.cpu.cfs_period_us
      lxc.cgroup.cpu.cfs_quota_us
      lxc.cgroup2.cpu.max
    ].each do |key|
      allow(raw_configs).to receive(:lxc).and_return("#{key} = 250000\n")

      expect { described_class.new(ct).configure }
        .to raise_error(
          OsCtld::ConfigError,
          "raw LXC key '#{key}' is managed by osctld"
        )
    end
  end

  it 'rejects raw includes which can hide lifecycle-owned keys' do
    allow(raw_configs).to receive(:lxc).and_return(
      "lxc.include = /etc/lxc/custom.conf\n"
    )

    expect { described_class.new(ct).configure }
      .to raise_error(
        OsCtld::ConfigError,
        "raw LXC key 'lxc.include' is managed by osctld"
      )
  end
end
# rubocop:enable RSpec/VerifiedDoubles
