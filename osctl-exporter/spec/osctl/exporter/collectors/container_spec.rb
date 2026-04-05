# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsCtl::Exporter::Collectors::Container do
  let(:manager) { instance_double(OsCtl::Exporter::Collector) }
  let(:registry) { OsCtl::Exporter::Registry.new }
  let(:collector) { described_class.new(manager, registry) }

  it 'builds dataset and network interface labels and pool lists' do
    ct = { pool: 'tank', id: 'ct1' }
    dataset = dataset_info(name: 'tank/ct/ct1', relative_name: '')
    netif = { type: 'routed', veth: 'veth0', name: 'eth0' }

    expect(collector.send(:dataset_labels, ct, dataset)).to eq(
      pool: 'tank',
      id: 'ct1',
      dataset: 'tank/ct/ct1',
      relative_name: ''
    )
    expect(collector.send(:netif_labels, ct, netif)).to eq(
      pool: 'tank',
      id: 'ct1',
      devicetype: 'routed',
      hostdevice: 'veth0',
      ctdevice: 'eth0'
    )
    expect(collector.send(:container_pools, [{ pool: 'tank' }, { pool: 'tank' }, { pool: 'backup' }]))
      .to eq(%w[tank backup])
  end

  it 'extracts container netifs and parses process states per container' do
    netifs = [
      { pool: 'tank', ctid: 'ct1', veth: 'veth0' },
      { pool: 'tank', ctid: 'ct2', veth: 'veth1' }
    ]
    expect(collector.send(:extract_container_netifs, { pool: 'tank', id: 'ct1' }, netifs)).to eq(
      [{ pool: 'tank', ctid: 'ct1', veth: 'veth0' }]
    )
    expect(netifs).to eq([{ pool: 'tank', ctid: 'ct2', veth: 'veth1' }])

    allow(OsCtl::Lib::ProcessList).to receive(:each)
      .with(parse_status: false)
      .and_yield(process_info(ct_id: %w[tank ct1], state: 'R'))
      .and_yield(process_info(ct_id: %w[tank ct1], state: 'S'))
      .and_yield(process_info(ct_id: %w[tank ct1], state: 'X'))
      .and_yield(process_info(ct_id: %w[tank ct2], state: 'R'))
      .and_yield(process_info(ct_id: ['tank', nil], state: 'R'))

    expect(collector.send(:parse_processes)).to eq(
      'tank' => {
        'ct1' => { 'R' => 1, 'S' => 1, 'D' => 0, 'Z' => 0, 'T' => 0, 't' => 0, 'X' => 1 },
        'ct2' => { 'R' => 1, 'S' => 0, 'D' => 0, 'Z' => 0, 'T' => 0, 't' => 0, 'X' => 0 }
      }
    )
  end

  it 'returns cached container data from the previous collection' do
    data = [{ id: 'ct1' }]
    collector.instance_variable_get(:@mutex).synchronize do
      collector.instance_variable_set(:@last_container_data, data)
    end

    expect(collector.get_last_container_data).to eq(data)
  end

  it 'reads JSON from a container network namespace successfully' do
    ct = { pool: 'tank', id: 'ct1', init_pid: Process.pid }
    sys = build_fake_sys
    allow(OsCtl::Lib::Sys).to receive(:new).and_return(sys)
    allow(File).to receive(:read).with('/proc/sys/net/netfilter/nf_conntrack_count').and_return("7\n")
    allow(File).to receive(:read).with('/proc/sys/net/netfilter/nf_conntrack_max').and_return("70\n")
    allow(collector).to receive(:collect) { collector.send(:read_from_container_netns, ct) }

    collector.run_collect(build_connected_osctld_client)

    expect(metric_values(registry.get(:osctl_container_nf_conntrack_entries))).to eq(
      { { pool: 'tank', id: 'ct1' } => 7.0 }
    )
    expect(metric_values(registry.get(:osctl_container_nf_conntrack_limit))).to eq(
      { { pool: 'tank', id: 'ct1' } => 70.0 }
    )
  end

  it 'logs and skips metrics when reading the container network namespace exits non-zero' do
    ct = { pool: 'tank', id: 'ct1', init_pid: Process.pid }
    sys = build_fake_sys
    allow(sys).to receive(:setns_path) { Process.exit!(3) }
    allow(OsCtl::Lib::Sys).to receive(:new).and_return(sys)
    allow(collector).to receive(:log)
    allow(collector).to receive(:collect) { collector.send(:read_from_container_netns, ct) }

    collector.run_collect(build_connected_osctld_client)

    expect(metric_values(registry.get(:osctl_container_nf_conntrack_entries))).to eq({})
    expect(collector).to have_received(:log).with(
      :warn,
      'Failed to read from netns of tank:ct1, exited with 3'
    )
  end

  it 'logs invalid JSON from the container network namespace' do
    ct = { pool: 'tank', id: 'ct1', init_pid: Process.pid }
    sys = build_fake_sys
    allow(OsCtl::Lib::Sys).to receive(:new).and_return(sys)
    allow(File).to receive(:read).with('/proc/sys/net/netfilter/nf_conntrack_count').and_return("7\n")
    allow(File).to receive(:read).with('/proc/sys/net/netfilter/nf_conntrack_max').and_return("70\n")
    allow(JSON).to receive(:parse).and_raise(JSON::ParserError, 'bad json')
    allow(collector).to receive(:log)
    allow(collector).to receive(:collect) { collector.send(:read_from_container_netns, ct) }

    collector.run_collect(build_connected_osctld_client)

    expect(metric_values(registry.get(:osctl_container_nf_conntrack_entries))).to eq({})
    expect(collector).to have_received(:log).with(
      :warn,
      include('Failed to parse JSON from netns of tank:ct1')
    )
  end

  it 'collects a small container dataset and wires its dependencies together' do
    cts = [
      {
        pool: 'tank',
        id: 'ct1',
        group_path: '/grp/ct1',
        state: 'running',
        dataset: 'tank/ct/ct1',
        uid_map: [{ 'inside_id' => 0, 'outside_id' => 100_000, 'count' => 65_536 }],
        init_pid: 123
      }
    ]
    netifs = [{ pool: 'tank', ctid: 'ct1', type: 'routed', veth: 'veth0', name: 'eth0' }]
    client = build_connected_osctld_client(
      client: instance_double(OsCtl::Client),
      list_containers: cts,
      list_netifs: netifs
    )
    objset = objset_info(write_bytes: 5, read_bytes: 6, write_ios: 7, read_ios: 8)
    dataset = dataset_info(name: 'tank/ct/ct1', relative_name: '')
    tree_dataset = tree_dataset_info(
      properties: {
        'used' => '100',
        'referenced' => '90',
        'available' => '1000',
        'quota' => '2000',
        'refquota' => '1500'
      },
      dataset:
    )
    tree_root = tree_root_info([tree_dataset])
    propreader = instance_double(OsCtl::Lib::Zfs::PropertyReader)
    netif_stats = instance_double(OsCtl::Lib::NetifStats)
    keyring = instance_double(OsCtl::Lib::KernelKeyring)

    allow(collector).to receive(:cg_init_subsystems)
    allow(collector).to receive(:cg_add_stats) do |data, *_args|
      data.first[:memory] = raw_value(1024)
      data.first[:cpu_user_us] = raw_value(11)
      data.first[:cpu_system_us] = raw_value(7)
      data.first[:nproc] = 3
    end
    allow(OsCtl::Lib::LoadAvgReader).to receive(:read_for).with(cts).and_return(
      'tank:ct1' => load_avg_info({ 1 => 0.1, 5 => 0.2, 15 => 0.3 })
    )
    allow(OsCtl::Lib::Zfs::ObjsetStats).to receive(:read_pools).with(['tank']).and_return(
      'tank/ct/ct1' => objset
    )
    allow(OsCtl::Lib::Zfs::PropertyReader).to receive(:new).and_return(propreader)
    allow(propreader).to receive(:read).with(
      ['tank/ct/ct1'],
      array_including(:used, :referenced, :available, :quota, :refquota),
      recursive: true
    ).and_return('tank/ct/ct1' => tree_root)
    allow(OsCtl::Lib::NetifStats).to receive(:new).and_return(netif_stats)
    allow(netif_stats).to receive(:cache_stats_for_interfaces).with(['veth0'])
    allow(netif_stats).to receive(:[]).with('veth0').and_return(
      tx: { bytes: 10, packets: 20 },
      rx: { bytes: 30, packets: 40 }
    )
    allow(OsCtl::Lib::KernelKeyring).to receive(:new).and_return(keyring)
    allow(OsCtl::Lib::IdMap).to receive(:from_hash_list).and_return(:uid_map)
    allow(keyring).to receive(:for_id_map).with(:uid_map).and_return(
      [keyring_usage_info(qnkeys: 2, qnbytes: 40)]
    )
    allow(OsCtl::Lib::ProcessList).to receive(:each)
      .with(parse_status: false)
      .and_yield(process_info(ct_id: %w[tank ct1], state: 'R'))
      .and_yield(process_info(ct_id: %w[tank ct1], state: 'S'))
    allow(collector).to receive(:read_from_container_netns)

    collector.run_collect(client)

    expect(metric_values(registry.get(:osctl_container_state_running))).to eq(
      { { pool: 'tank', id: 'ct1' } => 1.0 }
    )
    expect(metric_values(registry.get(:osctl_container_memory_used_bytes))).to eq(
      { { pool: 'tank', id: 'ct1' } => 1024.0 }
    )
    expect(metric_values(registry.get(:osctl_container_cpu_microseconds_total))).to eq(
      {
        { pool: 'tank', id: 'ct1', mode: 'user' } => 11.0,
        { pool: 'tank', id: 'ct1', mode: 'system' } => 7.0
      }
    )
    expect(metric_values(registry.get(:osctl_container_processes_pids))).to eq(
      { { pool: 'tank', id: 'ct1' } => 3.0 }
    )
    expect(metric_values(registry.get(:osctl_container_processes_state))).to include(
      { pool: 'tank', id: 'ct1', state: 'R' } => 1.0,
      { pool: 'tank', id: 'ct1', state: 'S' } => 1.0
    )
    expect(metric_values(registry.get(:osctl_container_load1))).to eq(
      { { pool: 'tank', id: 'ct1' } => 0.1 }
    )
    dataset_labels = { pool: 'tank', id: 'ct1', dataset: 'tank/ct/ct1', relative_name: '' }
    expect(metric_values(registry.get(:osctl_container_dataset_used_bytes))).to eq(
      { dataset_labels => 100.0 }
    )
    expect(metric_values(registry.get(:osctl_container_dataset_bytes_written))).to eq(
      { dataset_labels => 5.0 }
    )
    expect(metric_values(registry.get(:osctl_container_network_receive_bytes_total))).to eq(
      { { pool: 'tank', id: 'ct1', devicetype: 'routed', hostdevice: 'veth0', ctdevice: 'eth0' } => 10.0 }
    )
    expect(metric_values(registry.get(:osctl_container_keyring_qnkeys))).to eq(
      { { pool: 'tank', id: 'ct1' } => 2.0 }
    )
    expect(metric_values(registry.get(:osctl_container_keyring_qnbytes))).to eq(
      { { pool: 'tank', id: 'ct1' } => 40.0 }
    )
    expect(collector.get_last_container_data.first[:memory].raw).to eq(1024)
    expect(collector).to have_received(:read_from_container_netns).with(
      hash_including(pool: 'tank', id: 'ct1')
    )
  end
end
