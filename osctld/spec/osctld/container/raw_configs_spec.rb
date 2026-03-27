# frozen_string_literal: true

require 'osctld/container/raw_configs'

RSpec.describe OsCtld::Container::RawConfigs do
  it 'loads configs with symbolized keys' do
    configs = described_class.load('lxc' => 'lxc.include = common.conf')

    expect(configs.lxc).to eq('lxc.include = common.conf')
  end

  it 'supports the lxc getter and setter' do
    configs = described_class.new

    configs.lxc = 'lxc.mount.auto = cgroup'

    expect(configs.lxc).to eq('lxc.mount.auto = cgroup')
  end

  it 'omits nil values from the dump' do
    configs = described_class.new(lxc: nil)

    expect(configs.dump).to eq({})

    configs.lxc = 'lxc.include = common.conf'

    expect(configs.dump).to eq('lxc' => 'lxc.include = common.conf')
  end

  it 'duplicates config storage independently' do
    configs = described_class.new(lxc: 'lxc.include = common.conf')

    copy = configs.dup
    copy.lxc = 'lxc.mount.auto = cgroup'

    expect(configs.lxc).to eq('lxc.include = common.conf')
    expect(copy.lxc).to eq('lxc.mount.auto = cgroup')
  end
end
