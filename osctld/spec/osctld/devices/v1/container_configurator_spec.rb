# frozen_string_literal: true

require 'osctld/devices/v1/container_configurator'

RSpec.describe OsCtld::Devices::V1::ContainerConfigurator do
  let(:owner) do
    Struct.new(
      :base_cgroup_path,
      :active_cgroup_root,
      :cgroup_path,
      :lxc_payload_cgroup_path,
      :lxc_inner_cgroup_path,
      keyword_init: true
    ).new(
      base_cgroup_path: '/osctl/ct.ct1',
      active_cgroup_root: '/osctl/ct.ct1/runs/run-1',
      cgroup_path: '/osctl/ct.ct1/runs/run-1/user-owned',
      lxc_payload_cgroup_path: '/osctl/ct.ct1/runs/run-1/user-owned/payload',
      lxc_inner_cgroup_path: '/osctl/ct.ct1/runs/run-1/user-owned/payload/inner'
    )
  end

  it 'propagates dynamic device changes through the namespaced root' do
    paths = described_class.new(owner).send(:rel_ct_cgroup_paths)

    expect(paths).to include(
      ['/osctl/ct.ct1', true],
      ['/osctl/ct.ct1/runs', true],
      ['/osctl/ct.ct1/runs/run-1', true],
      ['/osctl/ct.ct1/runs/run-1/user-owned', true],
      ['/osctl/ct.ct1/runs/run-1/user-owned/payload', false],
      ['/osctl/ct.ct1/runs/run-1/user-owned/payload/inner', false]
    )
  end
end
