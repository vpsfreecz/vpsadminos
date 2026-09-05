# frozen_string_literal: true

require 'osctld/devices/device'
require 'osctld/devices/v1/container_configurator'

RSpec.describe OsCtld::Devices::V1::ContainerConfigurator do
  subject(:configurator) { configurator_class.new(Object.new) }

  let(:configurator_class) do
    Class.new(described_class) do
      def abs_group_cgroup_paths
        [['/cgroup/shared', true]]
      end

      def abs_ct_cgroup_paths
        [
          ['/cgroup/ct', true],
          ['/cgroup/ct/user-owned', true],
          ['/cgroup/ct/user-owned/lxc.payload.ct', false]
        ]
      end

      def prepare_cgroup(_cgpath, _create)
        true
      end
    end
  end
  let(:device) { OsCtld::Devices::Device.new(:char, 10, 200, 'rwm') }

  before do
    allow(OsCtld::CGroup).to receive(:set_param)
  end

  it 'removes devices only from container cgroups' do
    configurator.remove_device(device)

    expect(OsCtld::CGroup).not_to have_received(:set_param).with(
      '/cgroup/shared/devices.deny',
      anything
    )
    expect(OsCtld::CGroup).to have_received(:set_param).with(
      '/cgroup/ct/user-owned/lxc.payload.ct/devices.deny',
      ['c 10:200 rwm']
    ).ordered
    expect(OsCtld::CGroup).to have_received(:set_param).with(
      '/cgroup/ct/user-owned/devices.deny',
      ['c 10:200 rwm']
    ).ordered
    expect(OsCtld::CGroup).to have_received(:set_param).with(
      '/cgroup/ct/devices.deny',
      ['c 10:200 rwm']
    ).ordered
  end

  it 'applies only mode expansions to the shared cgroup' do
    configurator.apply_changes(
      allow: 'c 10:200 w',
      deny: 'c 10:200 m'
    )

    expect(OsCtld::CGroup).to have_received(:set_param).with(
      '/cgroup/shared/devices.allow',
      ['c 10:200 w']
    ).once
    expect(OsCtld::CGroup).not_to have_received(:set_param).with(
      '/cgroup/shared/devices.deny',
      anything
    )

    %w[
      /cgroup/ct
      /cgroup/ct/user-owned
      /cgroup/ct/user-owned/lxc.payload.ct
    ].each do |path|
      expect(OsCtld::CGroup).to have_received(:set_param).with(
        "#{path}/devices.allow",
        ['c 10:200 w']
      ).once
      expect(OsCtld::CGroup).to have_received(:set_param).with(
        "#{path}/devices.deny",
        ['c 10:200 m']
      ).once
    end
  end
end
