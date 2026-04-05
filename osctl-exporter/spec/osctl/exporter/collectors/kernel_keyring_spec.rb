# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsCtl::Exporter::Collectors::KernelKeyring do
  it 'exports metrics for each keyring user' do
    registry = OsCtl::Exporter::Registry.new
    collector = described_class.new(instance_double(OsCtl::Exporter::Collector), registry)
    key_users = [
      keyring_user_info(
        uid: 1000,
        usage: 1,
        nkeys: 2,
        nikeys: 3,
        qnkeys: 4,
        maxkeys: 5,
        qnbytes: 6,
        maxbytes: 7
      ),
      keyring_user_info(
        uid: 1001,
        usage: 8,
        nkeys: 9,
        nikeys: 10,
        qnkeys: 11,
        maxkeys: 12,
        qnbytes: 13,
        maxbytes: 14
      )
    ]
    allow(OsCtl::Lib::KernelKeyring).to receive(:new).and_return(key_users)

    collector.run_collect(build_disconnected_osctld_client)

    expect(metric_values(registry.get(:kernel_keyring_users_usage))).to eq(
      { { uid: '1000' } => 1.0, { uid: '1001' } => 8.0 }
    )
    expect(metric_values(registry.get(:kernel_keyring_users_nkeys))).to eq(
      { { uid: '1000' } => 2.0, { uid: '1001' } => 9.0 }
    )
    expect(metric_values(registry.get(:kernel_keyring_users_maxbytes))).to eq(
      { { uid: '1000' } => 7.0, { uid: '1001' } => 14.0 }
    )
  end
end
