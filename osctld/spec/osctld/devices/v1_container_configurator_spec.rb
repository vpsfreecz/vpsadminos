# frozen_string_literal: true

require 'osctld/cgroup'
require 'osctld/devices/configurator'
require 'osctld/devices/v1/container_configurator'

RSpec.describe OsCtld::Devices::V1::ContainerConfigurator do
  subject(:configurator) { described_class.new(owner) }

  let(:writes) { [] }
  let(:device) { 'c 10:200 rwm' }
  let(:paths) do
    %w[
      /devices/group/user
      /devices/group/user/ct
      /devices/group/user/ct/user-owned
      /devices/group/user/ct/user-owned/lxc.payload.testct
    ]
  end
  let(:owner) do
    group = Struct.new(:path) do
      def full_cgroup_path(_user)
        path
      end
    end.new('group/user')

    Struct.new(:id, :group, :user, :base_cgroup_path, :cgroup_path).new(
      'testct', group, nil, 'group/user/ct', 'group/user/ct/user-owned'
    )
  end

  before do
    allow(OsCtld::CGroup).to receive_messages(fs: '/', real_subsystem: 'devices')
    allow(OsCtld::CGroup).to receive(:set_param) { |path, values| writes << [path, values] }
    paths.each { |path| allow(Dir).to receive(:exist?).with(path).and_return(true) }
  end

  it 'removes a device bottom-up without revoking it from the shared parent' do
    configurator.remove_device(device)

    expected = paths.drop(1).reverse.map { |path| ["#{path}/devices.deny", [device]] }
    expect(writes).to eq(expected)
  end

  it 'changes container modes without changing the shared parent policy' do
    configurator.apply_changes(deny: 'c 10:200 w')

    expected = paths.drop(1).map { |path| ["#{path}/devices.deny", ['c 10:200 w']] }
    expect(writes).to eq(expected)
  end

  it 'propagates mode expansions but not restrictions through the shared parent' do
    configurator.apply_changes(allow: 'c 10:200 w', deny: 'c 10:200 m')

    expected = [["#{paths.first}/devices.allow", ['c 10:200 w']]]
    expected.concat(paths.drop(1).flat_map do |path|
      [
        ["#{path}/devices.allow", ['c 10:200 w']],
        ["#{path}/devices.deny", ['c 10:200 m']]
      ]
    end)
    expect(writes).to eq(expected)
  end

  it 'still allows a newly added device through the shared parent' do
    configurator.add_device(device)

    expected = paths.map { |path| ["#{path}/devices.allow", [device]] }
    expect(writes).to eq(expected)
  end

  it 'does not create the optional LXC payload cgroup while removing a device' do
    allow(Dir).to receive(:exist?).with(paths.last).and_return(false)

    configurator.remove_device(device)

    expected = paths[1..2].reverse.map { |path| ["#{path}/devices.deny", [device]] }
    expect(writes).to eq(expected)
  end
end
