# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsCtl::Cli::Top::Model do
  let(:options) { { enable_netif: false, enable_zfs: false } }
  let(:model) { described_class.new(**options) }
  let(:client) { instance_double(OsCtl::Client, open: nil, close: nil) }
  let(:sample_state) { {} }
  let(:cgroup_v1) { false }

  def init_stat(pid, ticks)
    columns = Array.new(20, '0')
    columns[0] = 'S'
    columns[19] = ticks.to_s
    "#{pid} (init with ) spaces) #{columns.join(' ')}\n"
  end

  def advance
    sample_state[:phase] += 1
    sample_state[:wall] += 15
    sample_state[:mono] += 15_000_000_000
    model.measure
  end

  def require_unlocked_acquisition
    current = sample_state[:model]
    raise 'I/O under publication mutex' if current && current.instance_variable_get(:@mutex).owned?
  end

  before do
    allow(UNIXSocket).to receive(:new).and_raise('unmocked daemon connection')
    sample_state[:phase] = 0
    sample_state[:wall] = 10
    sample_state[:mono] = 10_000_000_000
    sample_state[:inventory] = [
      { pool: 'pool', id: 'one', state: 'running', init_pid: 101, group_path: 'one/user-owned' },
      { pool: 'pool', id: 'two', state: 'running', init_pid: 102, group_path: 'two/user-owned' }
    ]
    sample_state[:runs] = { 101 => 99, 102 => 100, 111 => 200 }
    sample_state[:loads] = { 'pool:one' => [10.0, 5.0, 1.0], 'pool:two' => [30.0, 12.0, 6.0] }
    sample_state[:raw_override] = {}
    sample_state[:host_reset] = false
    allow(Time).to receive(:now) { Time.at(sample_state[:wall]) }

    allow(OsCtl::Client).to receive(:new).and_return(client)
    allow(OsCtl::Cli::Top::Monitor).to receive(:new).and_return(double(subscribe: nil, start: nil))
    allow(OsCtl::Lib::CGroup).to receive(:v1?).and_return(cgroup_v1)
    allow(client).to receive(:cmd_data!) do |command, **rpc_options|
      require_unlocked_acquisition
      case command
      when :ct_list
        raise 'live hostname requested' unless rpc_options == { read_hostname: false }

        sample_state[:inventory].map(&:dup)
      when :group_cgsubsystems
        {}
      when :pool_list
        raise 'disabled pool inventory' unless options.fetch(:enable_zfs, true)

        []
      when :netif_list
        raise 'disabled network inventory' unless options.fetch(:enable_netif, true)

        []
      else
        raise "optional acquisition attempted: #{command}"
      end
    end
    allow(File).to receive(:read).and_call_original
    allow(File).to receive(:read).with(%r{\A/proc/\d+/stat\z}) do |path|
      require_unlocked_acquisition
      pid = path.split('/')[2].to_i
      init_stat(pid, sample_state[:runs].fetch(pid))
    end
    allow(File).to receive(:open).and_call_original
    allow(File).to receive(:open).with('/proc/stat') do |&block|
      require_unlocked_acquisition
      phase = sample_state[:host_reset] ? 0 : sample_state[:phase]
      stat = [1000 + (phase * 3000), 0, 500 + (phase * 1500), 1000 + (phase * 4500), 0, 0, 0, 0, 0, 0]
      io = StringIO.new("cpu #{stat.join(' ')}\n")
      block ? block.call(io) : io
    end
    allow(OsCtl::Lib::MemInfo).to receive(:new).and_return(
      double(total: 64, used: 40, free: 24, buffers: 1, cached: 2, swap_total: 8, swap_used: 1, swap_free: 7)
    )
    allow(OsCtl::Lib::LoadAvg).to receive(:new).and_return(double(to_a: [20.0, 10.0, 4.0], total: 2))
    allow(OsCtl::Lib::LoadAvgReader).to receive(:read_for) do |_rows|
      require_unlocked_acquisition
      sample_state[:loads].transform_values { |values| double(averages: values) }
    end
    allow(OsCtl::Lib::CGroup::PathReader).to receive(:new) do |_subsystems, path|
      require_unlocked_acquisition
      raw = if path.empty?
              { cpu_us: 1000 + (sample_state[:phase] * 15_000), cpu_user_hz: 200 + (sample_state[:phase] * 3000),
                cpu_system_hz: 100 + (sample_state[:phase] * 1500), memory: 40 * 1024, nproc: 2 }
            elsif path == 'one/user-owned'
              { cpu_us: 1000 + (sample_state[:phase] * 900_000), nproc: 2, cpu_user_hz: 100 + (sample_state[:phase] * 600), cpu_system_hz: 50 + (sample_state[:phase] * 300),
                memory: 95, memory_limit: 100, cpu_limit: 200 }
            else
              { cpu_us: 1000 + (sample_state[:phase] * 450_000), nproc: 1, cpu_user_hz: 50 + (sample_state[:phase] * 300), cpu_system_hz: 50 + (sample_state[:phase] * 150),
                memory: 50, memory_limit: 100 }
            end
      reader = instance_double(OsCtl::Lib::CGroup::PathReader)
      allow(reader).to receive(:read_stats).with(%i[cpu_us cpu_hz cpu_limit memory memory_limit nproc], true)
                                           .and_return(raw.merge(path.empty? ? {} : sample_state[:raw_override]).transform_values do |v|
                                             v.is_a?(Numeric) ? OsCtl::Lib::Cli::Presentable.new(v) : v
                                           end)
      reader
    end
    net_stats = double(reset: nil)
    allow(net_stats).to receive(:get_stats_for_all) do
      { 'host0' => { tx: { bytes: 1000 + (sample_state[:phase] * 1500), packets: 100 + (sample_state[:phase] * 150) },
                     rx: { bytes: 2000 + (sample_state[:phase] * 3000), packets: 200 + (sample_state[:phase] * 300) } } }
    end
    allow(OsCtl::Lib::NetifStats).to receive(:new) do
      raise 'disabled netif reader constructed' unless options.fetch(:enable_netif, true)

      net_stats
    end
    stats = double(write_ios: 100, read_ios: 200, write_bytes: 1000, read_bytes: 2000)
    objsets = double(aggregate_stats: stats)
    allow(OsCtl::Lib::Zfs::ObjsetStats).to receive(:read_pools).and_return(objsets)
    arc = double(c_max: 1000, c: 900, size: 800, hit_rate: 95.0, misses: 2,
                 l2_size: 0, l2_asize: 0, l2_hit_rate: 0.0, l2_misses: 0)
    allow(OsCtl::Cli::Top::ArcStats).to receive(:new).and_return(arc)
    iostat = double('iostat', 'pools=': nil, start: nil, current_all: nil, stop: nil)
    allow(OsCtl::Lib::Zfs::IOStat).to receive(:new) do
      raise 'disabled iostat reader constructed' unless options.fetch(:enable_zfs, true) && options.fetch(:enable_iostat, true)

      iostat
    end
    stub_backticks(model, 'nproc' => "4\n")
    allow(model).to receive(:monotonic_ns) { sample_state[:mono] }
    sample_state[:model] = model
  end

  it 'never constructs or invokes optional collectors, events, network or hostname reads' do
    expect(OsCtl::Lib::Zfs::IOStat).not_to receive(:new)
    expect(OsCtl::Lib::Zfs::ObjsetStats).not_to receive(:read_pools)
    expect(OsCtl::Lib::NetifStats).not_to receive(:new)
    expect(OsCtl::Cli::Top::ArcStats).not_to receive(:new)
    expect_any_instance_of(OsCtl::Cli::Top::Measurement).not_to receive(:add_zfs_io_stats)
    expect_any_instance_of(OsCtl::Cli::Top::Measurement).not_to receive(:netif_stats)

    model.setup
    expect(model.data).to include(top_schema: 1, sequence: 1, complete: false, invalid_reason: 'initial_baseline')
    advance
    expect(model.data[:complete]).to be(true)
    expect(model.data[:collectors]).to eq(netif: false, zfs: false, iostat: false)
    expect(model.data[:zfs]).to be_nil
    model.data[:containers].each { |ct| expect(ct.values_at(:tx, :rx, :zfsio)).to all(be_nil) }
  end

  it 'retains the legacy CPU formula, current gauges and full synthetic-host ranking' do
    model.setup
    advance
    frame = JSON.parse(model.data.to_json)
    rows = frame.fetch('containers')
    expect(rows.map { |ct| ct['id'] }).to eq(['one', 'two', '[host]'])
    expect(rows.map { |ct| ct['cpu_usage'] }).to eq([40.0, 20.0, 140.0])
    expect(rows[0].slice('memory', 'memory_limit', 'cpu_limit', 'init_pid')).to eq(
      'memory' => 95, 'memory_limit' => 100, 'cpu_limit' => 200, 'init_pid' => 101
    )
    expect(rows[0]['cpu_usage'] / rows[0]['cpu_limit'] * 100).to eq(20.0)
    expect(rows[0]['memory'].to_f / rows[0]['memory_limit'] * 100).to eq(95.0)
    expect(rows[2]['memory']).to eq((40 * 1024) - 145)
    expect(rows.sort_by { |ct| -ct['loadavg'][0] }.map { |ct| ct['id'] }).to eq(['two', '[host]', 'one'])
    expect(frame['cpu']['idle']).to eq(50.0)
  end

  it 'exports stable run identity and distinguishes current sweep from the CPU window' do
    model.setup
    epoch = model.data[:epoch]
    advance
    expect(model.data).to include(epoch:, sequence: 2, complete: true,
                                  sample_started_monotonic_ns: 25_000_000_000,
                                  sample_completed_monotonic_ns: 25_000_000_000,
                                  measurement_window_started_monotonic_ns: 10_000_000_000,
                                  measurement_window_completed_monotonic_ns: 25_000_000_000)
    expect(model.data[:containers][0]).to include(init_pid: 101, init_start_time_ticks: 99, valid: true)
    advance
    expect(model.data).to include(sequence: 3, measurement_window_started_monotonic_ns: 25_000_000_000)
  end

  it 'publishes unlimited limits as nil while retaining their rows in the ranking' do
    sample_state[:raw_override] = { memory_limit: nil }
    # PathReader omits unlimited limits instead of reporting a failed nil read.
    allow(OsCtl::Lib::CGroup::PathReader).to receive(:new).and_return(
      double(read_stats: { cpu_user_hz: 10, cpu_system_hz: 10, memory: 50 })
    )
    model.setup
    advance
    expect(model.data[:complete]).to be(true)
    expect(model.data[:containers].map { |ct| ct[:memory_limit] }).to all(be_nil)
    expect(model.data[:containers].map { |ct| ct[:cpu_limit] }).to all(be_nil)
  end

  it 'rejects missing cgroup values and failed limit reads instead of skipping a gate' do
    model.setup
    sample_state[:raw_override] = { cpu_user_hz: nil }
    advance
    expect(model.data).to include(complete: false, invalid_reason: 'missing_cgroup_value')
    sample_state[:raw_override] = { cpu_limit: nil }
    advance
    expect(model.data).to include(complete: false, invalid_reason: 'missing_cgroup_value')
  end

  it 'rejects zero limits and nonfinite measurements' do
    model.setup
    sample_state[:raw_override] = { memory_limit: 0 }
    advance
    expect(model.data).to include(complete: false, invalid_reason: 'invalid_limit')
    sample_state[:raw_override] = { memory: Float::INFINITY }
    advance
    expect(model.data).to include(complete: false, invalid_reason: 'missing_cgroup_value')
  end

  it 'never fabricates zero load for a missing container' do
    model.setup
    sample_state[:loads].delete('pool:one')
    advance
    expect(model.data).to include(complete: false, invalid_reason: 'missing_container_load', loadavg: nil)
    expect(model.instance_variable_get(:@baseline_started)).to be_nil
  end

  it 'clears failed baselines and then seeds recovery without endless warming' do
    model.setup
    allow(OsCtl::Lib::LoadAvgReader).to receive(:read_for).and_raise(Errno::EIO)
    advance
    expect(model.data).to include(complete: false, invalid_reason: 'required_read_failed')
    allow(OsCtl::Lib::LoadAvgReader).to receive(:read_for) do |_|
      sample_state[:loads].transform_values { |values| double(averages: values) }
    end
    advance
    expect(model.data).to include(complete: false, invalid_reason: 'initial_baseline')
    advance
    expect(model.data[:complete]).to be(true)
    expect(model.data[:measurement_window_started_monotonic_ns]).to eq(40_000_000_000)
  end

  it 'uses a new run as seed without computing a delta from the old PID or start time' do
    model.setup
    sample_state[:inventory][0][:init_pid] = 111
    advance
    expect(model.data).to include(complete: false, invalid_reason: 'initial_baseline')
    expect(model.data[:containers][0]).to include(init_pid: 111, init_start_time_ticks: 200, cpu_usage: nil)
    advance
    expect(model.data[:complete]).to be(true)
    sample_state[:runs][111] = 201
    advance
    expect(model.data).to include(complete: false, invalid_reason: 'initial_baseline')
  end

  it 'rejects a run changing during required acquisition and discards that sweep' do
    model.setup
    reads = 0
    allow(File).to receive(:read).with('/proc/101/stat') do
      reads += 1
      init_stat(101, reads == 1 ? 99 : 200)
    end
    advance
    expect(model.data).to include(complete: false, invalid_reason: 'run_changed')
    expect(model.instance_variable_get(:@baseline_started)).to be_nil
  end

  it 'rejects inconsistent or duplicate running inventory' do
    model.setup
    allow(client).to receive(:cmd_data!).with(:ct_list, read_hostname: false)
                                        .and_return(sample_state[:inventory], sample_state[:inventory].drop(1))
    advance
    expect(model.data).to include(complete: false, invalid_reason: 'inventory_changed')
    allow(client).to receive(:cmd_data!).with(:ct_list, read_hostname: false)
                                        .and_return([sample_state[:inventory][0], sample_state[:inventory][0]])
    advance
    expect(model.data).to include(complete: false, invalid_reason: 'invalid_inventory')
  end

  it 'invalidates counter resets but retains coherent current raw values as the next baseline' do
    model.setup
    sample_state[:raw_override] = { cpu_user_hz: 0 }
    advance
    expect(model.data).to include(complete: false, invalid_reason: 'counter_reset')
    sample_state[:raw_override] = { cpu_user_hz: 100 }
    advance
    expect(model.data[:complete]).to be(true)
  end

  it 'rejects a reset or zero host denominator rather than publishing NaN or eligibility' do
    model.setup
    sample_state[:host_reset] = true
    advance
    expect(model.data).to include(complete: false, invalid_reason: 'invalid_host_cpu_delta')
    sample_state[:host_reset] = false
    advance
    expect(model.data[:complete]).to be(true)
  end

  it 'reports long sweeps without imposing a consumer freshness policy' do
    model.setup
    allow(model).to receive(:monotonic_ns).and_return(25_000_000_000, 31_000_000_000)
    advance
    expect(model.data).to include(complete: true, sample_started_monotonic_ns: 25_000_000_000,
                                  sample_completed_monotonic_ns: 31_000_000_000)
  end

  it 'does no acquisition or retiming on data reads, mutations of returned data, or mode changes' do
    model.setup
    advance
    original = model.data
    expect(client).not_to receive(:cmd_data!)
    expect(File).not_to receive(:read)
    expect(OsCtl::Lib::MemInfo).not_to receive(:new)
    expect(OsCtl::Lib::LoadAvg).not_to receive(:new)
    sample_state[:mono] += 1_000_000_000
    copy = model.data
    copy[:containers].reverse!
    expect(model.data).to eq(original)
    model.mode = :cumulative
    expect(model.data.slice(:sequence, :sample_completed_monotonic_ns)).to eq(
      original.slice(:sequence, :sample_completed_monotonic_ns)
    )
  end

  it 'invalidates a generation changed during acquisition and clears its old baseline' do
    model.setup
    allow(OsCtl::Lib::LoadAvgReader).to receive(:read_for) do
      model.sync { model.changed! }
      sample_state[:loads].transform_values { |values| double(averages: values) }
    end
    advance
    expect(model.data).to include(complete: false, invalid_reason: 'inventory_changed')
    expect(model.instance_variable_get(:@baseline_started)).to be_nil
  end

  it 'removes the current identity even when an event captured a prior snapshot object' do
    previous = model.containers.first
    model.setup
    advance
    expect(model.containers.first).not_to equal(previous)
    model.remove_ct(previous)
    expect(model.find_ct('pool', 'one')).to be_nil
    expect(model.containers.map(&:id)).to eq(['two'])
  end

  it 'never looks up an interface when its collector is disabled' do
    ct = model.containers.first
    expect(OsCtl::Client).not_to receive(:new)
    expect(client).not_to receive(:cmd_data!)
    model.add_ct_netif(ct, 'eth0')
  end

  it 'includes projection work in the monotonic sweep envelope' do
    model.setup
    allow(model).to receive(:project).and_wrap_original do |original, *args|
      result = original.call(*args)
      sample_state[:mono] += 1_000_000_000
      result
    end
    advance
    expect(model.data).to include(complete: true, sample_started_monotonic_ns: 25_000_000_000,
                                  sample_completed_monotonic_ns: 27_000_000_000,
                                  measurement_window_completed_monotonic_ns: 27_000_000_000)
  end

  context 'with ordinary defaults' do
    let(:options) { {} }

    it 'retains successful core values, network/ZFS fields and effective flags' do
      model.setup
      advance
      frame = JSON.parse(model.data.to_json)
      expect(frame['complete']).to be(true)
      expect(frame['collectors']).to eq('netif' => true, 'zfs' => true, 'iostat' => true)
      expect(frame['containers'].map { |ct| ct['cpu_usage'] }).to eq([40.0, 20.0, 140.0])
      expect(frame['containers'][0]).to include('memory' => 95, 'cpu_us' => 60_000, 'cpu_user_hz' => 40, 'cpu_system_hz' => 20, 'nproc' => 2)
      expect(frame['containers'][0]['tx']).to eq('bytes' => 0, 'packets' => 0)
      expect(frame['containers'][0]['zfsio']).to eq('ios' => { 'w' => 0, 'r' => 0 }, 'bytes' => { 'w' => 0, 'r' => 0 })
      expect(frame['zfs']['arcstats']['arc']).to include('hit_rate' => 95.0, 'misses' => 2)
      expect(OsCtl::Lib::NetifStats).to have_received(:new)
      expect(OsCtl::Lib::Zfs::ObjsetStats).to have_received(:read_pools).twice
      expect(OsCtl::Cli::Top::ArcStats).to have_received(:new).twice
    end

    it 'performs monitor container lookups outside the publication mutex' do
      attrs = { pool: 'pool', id: 'three', state: 'running', init_pid: 111, group_path: 'three/user-owned' }
      allow(client).to receive(:cmd_data!).with(:ct_show, pool: 'pool', id: 'three', read_hostname: false) do
        require_unlocked_acquisition
        attrs
      end
      # The acquisition fixture substitutes Monitor construction, so use the
      # real instance method on an allocated monitor without a subscription.
      monitor = OsCtl::Cli::Top::Monitor.allocate
      monitor.instance_variable_set(:@model, model)
      monitor.send(:process_event, :db, object: 'container', action: 'add', pool: 'pool', id: 'three')
      expect(model.find_ct('pool', 'three').id).to eq('three')
    end

    it 'publishes optional failure as null without invalidating coherent core or partial host totals' do
      model.setup
      allow(OsCtl::Lib::Zfs::ObjsetStats).to receive(:read_pools).and_raise(Errno::EIO)
      allow(OsCtl::Cli::Top::ArcStats).to receive(:new).and_raise(Errno::EIO)
      advance
      expect(model.data[:complete]).to be(true)
      expect(model.data[:zfs]).to be_nil
      expect(model.data[:containers].map { |ct| ct[:zfsio] }).to all(be_nil)
    end
  end

  context 'with only iostat disabled' do
    let(:options) { { enable_iostat: false } }

    it 'retains ARC and objsets while skipping iostat construction' do
      # Initialization has already occurred; this also verifies the constructor
      # through its effective flag and that no worker was started.
      model.setup
      advance
      expect(model.data[:collectors]).to eq(netif: true, zfs: true, iostat: false)
      expect(OsCtl::Lib::Zfs::IOStat).not_to have_received(:new)
      expect(model.data[:zfs][:arcstats]).not_to be_nil
      expect(model.data[:zfs][:iostat]).to be_nil
    end
  end

  context 'with cgroup v1' do
    let(:cgroup_v1) { true }

    it 'uses the existing subsystem mapping and the same projection' do
      model.setup
      advance
      expect(model.data[:complete]).to be(true)
      expect(client).to have_received(:cmd_data!).with(:group_cgsubsystems).once
    end
  end
end
