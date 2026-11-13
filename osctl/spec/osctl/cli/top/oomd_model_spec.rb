# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsCtl::Cli::Top::OomdModel do
  let(:model) { described_class.new }
  let(:client) { instance_double(OsCtl::Client, open: nil, close: nil) }
  let(:fields) { %i[pool id loadavg memory memory_limit cpu_usage cpu_limit] }
  let(:sample_state) { {} }

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

  def projection(frame)
    frame[:containers].map { |ct| fields.to_h { |field| [field, ct[field]] } }
  end

  before do
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
    allow(model).to receive(:monotonic_ns) { sample_state[:mono] }
    allow(IO).to receive(:popen).with(['nproc']).and_return("4\n")
    allow(OsCtl::Client).to receive(:new).and_return(client)
    allow(OsCtl::Lib::CGroup).to receive(:v1?).and_return(false)
    allow(client).to receive(:cmd_data!) do |command, **options|
      case command
      when :ct_list
        raise 'hostname or unfiltered inventory requested' unless options == { state: ['running'], read_hostname: false }

        sample_state[:inventory].map(&:dup)
      when :group_cgsubsystems
        {}
      else
        raise "optional acquisition attempted: #{command}"
      end
    end
    allow(File).to receive(:read).and_call_original
    allow(File).to receive(:read).with(%r{\A/proc/\d+/stat\z}) do |path|
      pid = path.split('/')[2].to_i
      init_stat(pid, sample_state[:runs].fetch(pid))
    end
    allow(File).to receive(:open).and_call_original
    allow(File).to receive(:open).with('/proc/stat') do |&block|
      phase = sample_state[:host_reset] ? 0 : sample_state[:phase]
      stat = [1000 + (phase * 3000), 0, 500 + (phase * 1500), 1000 + (phase * 4500), 0, 0, 0, 0, 0, 0]
      block.call(StringIO.new("cpu #{stat.join(' ')}\n"))
    end
    allow(OsCtl::Lib::MemInfo).to receive(:new).and_return(
      double(total: 64, used: 40, free: 24, buffers: 1, cached: 2, swap_total: 8, swap_used: 1, swap_free: 7)
    )
    allow(OsCtl::Lib::LoadAvg).to receive(:new).and_return(double(to_a: [20.0, 10.0, 4.0]))
    allow(OsCtl::Lib::LoadAvgReader).to receive(:read_for) do |_rows|
      sample_state[:loads].transform_values { |values| double(averages: values) }
    end
    allow(OsCtl::Lib::CGroup::PathReader).to receive(:new) do |_subsystems, path|
      raw = if path == 'one/user-owned'
              { cpu_user_hz: 100 + (sample_state[:phase] * 600), cpu_system_hz: 50 + (sample_state[:phase] * 300),
                memory: 95, memory_limit: 100, cpu_limit: 200 }
            else
              { cpu_user_hz: 50 + (sample_state[:phase] * 300), cpu_system_hz: 50 + (sample_state[:phase] * 150),
                memory: 50, memory_limit: 100 }
            end
      reader = instance_double(OsCtl::Lib::CGroup::PathReader)
      allow(reader).to receive(:read_stats).with(%i[cpu_hz cpu_limit memory memory_limit], true)
                                           .and_return(raw.merge(sample_state[:raw_override]))
      reader
    end
  end

  it 'never constructs or invokes optional collectors, events, network or hostname reads' do
    expect(OsCtl::Cli::Top::Monitor).not_to receive(:new)
    expect(OsCtl::Cli::Top::Host).not_to receive(:new)
    expect(OsCtl::Lib::Zfs::IOStat).not_to receive(:new)
    expect(OsCtl::Lib::Zfs::ObjsetStats).not_to receive(:read_pools)
    expect(OsCtl::Lib::NetifStats).not_to receive(:new)
    expect(OsCtl::Cli::Top::ArcStats).not_to receive(:new)
    expect_any_instance_of(OsCtl::Cli::Top::Measurement).not_to receive(:add_zfs_io_stats)
    expect_any_instance_of(OsCtl::Cli::Top::Measurement).not_to receive(:netif_stats)

    model.setup
    expect(model.data).to include(oomd_schema: 1, sequence: 1, complete: false, invalid_reason: 'initial_baseline')
    advance
    expect(model.data[:complete]).to be(true)
    expect(client).to have_received(:close).twice
  end

  it 'matches the actual legacy numeric projection and full host-inclusive ranking' do
    model.setup
    previous = model.instance_variable_get(:@baseline)
    advance
    current = model.instance_variable_get(:@baseline)
    cpu = current[:cpu].diff(previous[:cpu])
    host_result = { cpu_user_hz: 200, cpu_system_hz: 100, memory: 40 * 1024,
                    memory_limit: nil, cpu_limit: nil }
    host = double(setup?: true, result: host_result, cpu_result: cpu, zfs_result: {}, id: '[host]')
    containers = sample_state[:inventory].map do |attrs|
      ct = OsCtl::Cli::Top::Container.new(attrs)
      key = [attrs[:pool], attrs[:id]]
      ct.instance_variable_set(:@measurements, [previous[:measurements][key], current[:measurements][key]])
      ct
    end
    legacy = OsCtl::Cli::Top::Model.allocate
    { mutex: Mutex.new, mode: :realtime, nproc: 4, host:, containers:,
      ct_lavgs: current[:loads] }.each { |key, value| legacy.instance_variable_set(:"@#{key}", value) }

    expect(projection(model.data)).to eq(projection(legacy.data))
    rows = model.data[:containers]
    expect(rows.map { |ct| ct[:cpu_usage] }).to eq([40.0, 20.0, 140.0])
    expect(rows[0][:cpu_usage] / rows[0][:cpu_limit] * 100).to eq(20.0)
    expect(rows[0][:memory].to_f / rows[0][:memory_limit] * 100).to eq(95.0)
    expect(rows.sort_by { |ct| -ct[:loadavg][0] }.map { |ct| ct[:id] }).to eq(['two', '[host]', 'one'])
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
    expect(model.instance_variable_get(:@baseline)).to be_nil
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
    expect(model.data).to include(complete: false, invalid_reason: 'run_changed')
    expect(model.data[:containers][0]).to include(init_pid: 111, init_start_time_ticks: 200, cpu_usage: nil)
    advance
    expect(model.data[:complete]).to be(true)
    sample_state[:runs][111] = 201
    advance
    expect(model.data).to include(complete: false, invalid_reason: 'run_changed')
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
    expect(model.instance_variable_get(:@baseline)).to be_nil
  end

  it 'rejects inconsistent or duplicate running inventory' do
    model.setup
    allow(client).to receive(:cmd_data!).with(:ct_list, state: ['running'], read_hostname: false)
                                        .and_return(sample_state[:inventory], sample_state[:inventory].drop(1))
    advance
    expect(model.data).to include(complete: false, invalid_reason: 'inventory_changed')
    allow(client).to receive(:cmd_data!).with(:ct_list, state: ['running'], read_hostname: false)
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

  it 'invalidates a sweep over five seconds and does not carry its old baseline forward' do
    model.setup
    allow(model).to receive(:monotonic_ns).and_return(25_000_000_000, 31_000_000_000, 31_000_000_000)
    advance
    expect(model.data).to include(complete: false, invalid_reason: 'stale_sweep')
    expect(model.instance_variable_get(:@baseline)).to be_nil
  end

  it 'requests the existing v1 subsystem mapping without optional inventory commands' do
    allow(OsCtl::Lib::CGroup).to receive(:v1?).and_return(true)
    model.setup
    advance
    expect(model.data[:complete]).to be(true)
    expect(client).to have_received(:cmd_data!).with(:group_cgsubsystems).twice
  end
end
