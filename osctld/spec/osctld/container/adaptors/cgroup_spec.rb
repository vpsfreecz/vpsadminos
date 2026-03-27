# frozen_string_literal: true

require 'osctld/container/adaptor'
require 'osctld/container/adaptors/cgroup'

CGroupAdaptorSpecContainer = Struct.new(:log_type, keyword_init: true)

RSpec.describe OsCtld::Container::Adaptor::CGroup do
  let(:ct) { instance_double(CGroupAdaptorSpecContainer, log_type: 'ct=tank:ct1') }
  let(:systemd_force_v1_option) { 'systemd.unified_cgroup_hierarchy=0' }
  let(:systemd_force_v2_option) { 'systemd.unified_cgroup_hierarchy=1' }

  before do
    stub_const('OsCtld::CGroup', Module.new do
      def self.version
        1
      end
    end)
  end

  def adapt(config)
    adaptor = described_class.new(ct, config)
    allow(adaptor).to receive(:log)
    adaptor.adapt
  end

  it 'adds the force-v1 option for systemd distros on cgroup v1' do
    allow(OsCtld::CGroup).to receive(:version).and_return(1)

    config = adapt(
      'distribution' => 'ubuntu',
      'version' => '22.04',
      'init_cmd' => ['/sbin/init']
    )

    expect(config['init_cmd']).to eq(['/sbin/init', systemd_force_v1_option])
  end

  it 'switches to force-v2 for cgroup-v2-only distros on cgroup v1' do
    allow(OsCtld::CGroup).to receive(:version).and_return(1)

    config = adapt(
      'distribution' => 'arch',
      'version' => 'rolling',
      'init_cmd' => ['/sbin/init', systemd_force_v1_option]
    )

    expect(config['init_cmd']).to eq(['/sbin/init', systemd_force_v2_option])
  end

  it 'removes force-v1 and force-v2 flags on cgroup v2' do
    allow(OsCtld::CGroup).to receive(:version).and_return(2)

    config = adapt(
      'distribution' => 'ubuntu',
      'version' => '22.04',
      'init_cmd' => ['/sbin/init', systemd_force_v1_option, systemd_force_v2_option]
    )

    expect(config['init_cmd']).to eq(['/sbin/init'])
  end

  it 'leaves non-systemd distros unchanged' do
    allow(OsCtld::CGroup).to receive(:version).and_return(1)

    config = {
      'distribution' => 'nixos',
      'version' => '24.11',
      'init_cmd' => ['/init']
    }

    expect(adapt(config.dup)).to eq(config)
  end

  it 'initializes a missing init command before appending cgroup flags' do
    allow(OsCtld::CGroup).to receive(:version).and_return(1)

    config = adapt(
      'distribution' => 'ubuntu',
      'version' => '22.04'
    )

    expect(config['init_cmd']).to eq(['/sbin/init', systemd_force_v1_option])
  end
end
