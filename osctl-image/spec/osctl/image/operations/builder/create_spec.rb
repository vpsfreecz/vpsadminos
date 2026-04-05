# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsCtl::Image::Operations::Builder::Create do
  subject(:op) { test_class.new(builder, '/scripts', vpsadminos_dir:) }

  let(:test_class) do
    Class.new(described_class) do
      def sleep(*)
        nil
      end
    end
  end

  let(:builder) do
    instance_double(
      OsCtl::Image::Builder,
      ctid: 'builder-1',
      name: 'default',
      distribution: 'alpine',
      version: '3.20',
      arch: 'x86_64',
      vendor: 'vendor',
      variant: 'minimal',
      load_attrs: nil
    )
  end

  let(:client) { instance_double(OsCtl::Image::OsCtldClient) }
  let(:calls) { [] }
  let(:vpsadminos_dir) { '/repo' }

  before do
    allow(OsCtl::Image::OsCtldClient).to receive(:new).and_return(client)
    allow(client).to receive(:batch).and_yield
    allow(OsCtl::Image::Operations::Builder::WaitForNetwork).to receive(:run)
    allow(OsCtl::Image::Operations::Builder::ControlledExec).to receive(:run).and_return(0)

    %i[
      create_container_from_repo
      set_container_attr
      set_container_nesting
      unset_container_start_menu
      add_netif_bridge
      set_container_dns_resolvers
      start_container
      bind_mount
      activate_mount
      unmount
      delete_container
    ].each do |method_name|
      allow(client).to receive(method_name) do |*args, **kwargs|
        calls << [method_name, args, kwargs]
        nil
      end
    end

    allow(client).to receive(:find_container).and_return(id: 'builder-1')
    allow(builder).to receive(:load_attrs) do |arg|
      calls << [:load_attrs, [arg], {}]
      nil
    end
  end

  it 'creates and prepares the builder container, mounts paths, runs setup and unmounts afterwards' do
    op.execute

    expect(calls).to include(
      [:create_container_from_repo, %w[builder-1 alpine 3.20 x86_64 vendor minimal], {}],
      [:set_container_attr, ['builder-1', 'org.vpsadminos.osctl-image:type', 'builder'], {}],
      [:set_container_attr, ['builder-1', 'org.vpsadminos.osctl-image:builder-name', 'default'], {}],
      [:set_container_nesting, ['builder-1'], {}],
      [:unset_container_start_menu, ['builder-1'], {}],
      [:add_netif_bridge, %w[builder-1 eth0 lxcbr0], {}],
      [:set_container_dns_resolvers, ['builder-1', %w[1.1.1.1 8.8.8.8]], {}],
      [:start_container, ['builder-1'], {}],
      [:load_attrs, [client], {}],
      [:bind_mount, ['builder-1', '/scripts', op.send(:builder_base_dir)], { map_ids: false }],
      [:activate_mount, ['builder-1', op.send(:builder_base_dir)], {}],
      [:bind_mount, ['builder-1', '/repo', op.send(:builder_vpsadminos_dir)], { map_ids: false }],
      [:activate_mount, ['builder-1', op.send(:builder_vpsadminos_dir)], {}],
      [:unmount, ['builder-1', op.send(:builder_vpsadminos_dir)], {}],
      [:unmount, ['builder-1', op.send(:builder_base_dir)], {}]
    )

    expect(OsCtl::Image::Operations::Builder::WaitForNetwork).to have_received(:run).with(builder)
    expect(OsCtl::Image::Operations::Builder::ControlledExec).to have_received(:run).with(
      builder,
      [
        File.join(op.send(:builder_base_dir), 'bin', 'runner'),
        'builder',
        'setup',
        'default'
      ],
      id: op.setup_id,
      client: client,
      env: { 'OSCTL_IMAGE_VPSADMINOS_DIR' => op.send(:builder_vpsadminos_dir) }
    )
  end

  it 'omits the vpsadminos bind mount and environment when no checkout is provided' do
    cmd = test_class.new(builder, '/scripts')

    cmd.execute

    expect(OsCtl::Image::Operations::Builder::ControlledExec).to have_received(:run).with(
      builder,
      kind_of(Array),
      id: kind_of(String),
      client: client,
      env: {}
    )
    expect(calls.none? { |method_name, method_args, _kwargs| method_name == :bind_mount && method_args[1] == '/repo' }).to be(true)
  end

  it 'deletes the builder container when setup fails' do
    allow(OsCtl::Image::Operations::Builder::ControlledExec).to receive(:run).and_return(1)

    expect { op.execute }
      .to raise_error(OsCtl::Image::OperationError, 'builder setup failed with exit status 1')

    expect(client).to have_received(:delete_container).with('builder-1')
  end

  it 'deletes the builder container when osctld raises an error during setup' do
    allow(client).to receive(:create_container_from_repo).and_raise(OsCtl::Client::Error, 'boom')

    expect { op.execute }.to raise_error(OsCtl::Client::Error, 'boom')
    expect(client).to have_received(:delete_container).with('builder-1')
  end
end
