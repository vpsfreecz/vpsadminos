# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'timeout'

RSpec.describe OsCtl::Cli::Top::PartialModel do
  let!(:state) do
    {
      inventory: [
        { pool: 'tank', id: '101', init_pid: 201, group_path: 'ct101/user-owned', state: 'running' },
        { pool: 'tank', id: '102', init_pid: 202, group_path: 'ct102/user-owned', state: 'running' },
        { pool: 'tank', id: '103', state: 'stopped' }
      ],
      time: 100_000_000_000, phase: 0, ticks: { 201 => 12_345, 202 => 23_456 },
      missing: {}, loads: { 'tank:101' => [12.0, 7.0, 3.0], 'tank:102' => [2.0, 1.0, 0.5] }
    }
  end
  let(:collectors) { { enable_netif: false, enable_zfs: false } }
  let(:client) { instance_double(OsCtl::Client, open: nil) }
  let(:partial) { new_model(described_class) }

  def v1 = false

  def new_model(klass)
    model = klass.new(**collectors)
    stub_backticks(model, 'nproc' => "4\n")
    allow(model).to receive(:monotonic_ns).and_return(state[:time], state[:time] + 200_000_000)
    if model.is_a?(described_class)
      allow(model).to receive(:counter_clock) { state[:time] }
    end
    model
  end

  def stats(path)
    phase = state[:phase]
    data = case path
           when ''
             { cpu_us: 10_000_000 + (phase * 9_000_000), cpu_user_hz: 100, cpu_system_hz: 200,
               memory: 2_000_000_000, nproc: 150 }
           when 'ct101/user-owned'
             { cpu_us: 10_000 + (phase * 27_000_000), cpu_user_hz: 100 + (phase * 1_800),
               cpu_system_hz: 100 + (phase * 900), cpu_limit: 200.0, memory: 1_006_632_960,
               memory_limit: 1_048_576_000, nproc: 81 }
           else
             { cpu_us: 10_000 + (phase * 3_000_000), cpu_user_hz: 100 + (phase * 150),
               cpu_system_hz: 100 + (phase * 150), memory: 250_000_000, memory_limit: 536_870_912, nproc: 9 }
           end
    data.merge(state[:missing].fetch(path, {}))
  end

  def advance(*models)
    state[:phase] += 1
    state[:time] += 15_000_000_000
    models.each do |model|
      allow(model).to receive(:monotonic_ns).and_return(state[:time], state[:time] + 200_000_000)
      model.measure
    end
  end

  def row(frame, id)
    frame.fetch(:containers).find { |ct| ct[:id] == id }
  end

  def subset(value, example)
    case example
    when Hash then example.to_h { |k, v| [k, subset(value.fetch(k), v)] }
    when Array then value.each_with_index.map { |item, i| subset(item, example.fetch(i)) }
    else value
    end
  end

  before do
    allow(OsCtl::Client).to receive(:new).and_return(client)
    allow(client).to receive(:close)
    allow(OsCtl::Cli::Top::Monitor).to receive(:new).and_wrap_original do |constructor, model|
      constructor.call(model).tap do |monitor|
        allow(monitor).to receive(:subscribe)
        allow(monitor).to receive(:start) { model.monitor_ready }
      end
    end
    allow(client).to receive(:cmd_data!).with(:ct_list, read_hostname: false) { state[:inventory]&.map(&:dup) }
    allow(client).to receive(:cmd_data!).with(:group_cgsubsystems).and_return({})
    allow(OsCtl::Lib::CGroup).to receive(:v1?).and_return(v1)
    allow(Time).to receive(:now) { Time.at(state.fetch(:wall, state[:time]) / 1_000_000_000) }
    allow(File).to receive(:read).and_call_original
    allow(File).to receive(:read).with(%r{\A/proc/(?:self/fd/)?\d+/(stat|status|cgroup)\z}) do |path|
      pid, name = path.split('/').last(2)
      pid = pid.to_i
      ct = state[:inventory].find { |item| item[:init_pid] == pid }
      payload = "/#{ct[:group_path]}/lxc.payload.#{ct[:id]}"
      overrides = state.fetch(:proc, {}).fetch(pid, {})
      defaults = { 'stat' => "#{pid} (init ) with spaces) S #{'0 ' * 18}#{state[:ticks].fetch(pid)}\n",
                   'status' => "NSpid:\t#{pid}\t1\n", 'cgroup' => "#{v1 ? '5:devices,freezer:' : '0::'}#{payload}/init.scope\n" }
      overrides.fetch(name) { defaults.fetch(name) }
    end
    allow(File).to receive(:readlink).and_call_original
    allow(File).to receive(:readlink).with(%r{\A/proc/self/fd/\d+/ns/cgroup\z}) do |path|
      pid = path.split('/')[-3].to_i
      state.fetch(:namespaces, {}).fetch(pid, "cgroup:[#{pid}]")
    end
    allow(File).to receive(:open).and_call_original
    allow(File).to receive(:open).with(%r{\A/proc/\d+\z}) do |path, &block|
      pid = path.split('/').last.to_i
      state[:proc_reads]&.push(pid)
      block.call(instance_double(File, fileno: pid))
    end
    allow(File).to receive(:foreach).and_call_original
    allow(File).to receive(:foreach).with(OsCtl::Lib::LoadAvgReader::FILE) do |_, &block|
      state[:inventory].each do |ct|
        load = state[:loads]["#{ct[:pool]}:#{ct[:id]}"]
        block.call("#{ct[:init_pid]} #{load.join(' ')} 1/4\n") if load
      end
      state[:during]&.call
    end
    allow(File).to receive(:open).with('/proc/stat') do |&block|
      phase = state.fetch(:host_phase, state[:phase])
      block.call(StringIO.new("cpu #{1000 + (phase * 1500)} 0 #{2000 + (phase * 3000)} #{5000 + (phase * 1500)} 0 0 0 0 0 0\n"))
    end
    allow(OsCtl::Lib::MemInfo).to receive(:new).and_return(
      double(total: 4_000_000, used: 2_000_000, free: 2_000_000, buffers: 0, cached: 0,
             swap_total: 0, swap_used: 0, swap_free: 0)
    )
    allow(OsCtl::Lib::LoadAvg).to receive(:new).and_return(double(to_a: [20.0, 10.0, 5.0], total: 150))
    allow(OsCtl::Lib::LoadAvgReader).to receive(:read_for) do |rows|
      rows.to_h { |ct| [ct.ident, double(averages: state[:loads][ct.ident])] }
    end
    allow(OsCtl::Lib::CGroup::PathReader).to receive(:new) do |_, path|
      values = stats(path)
      reader = instance_double(OsCtl::Lib::CGroup::PathReader)
      allow(reader).to receive(:read_stats) do |fields, _precise|
        names = fields.include?(:cpu_hz) ? fields + %i[cpu_user_hz cpu_system_hz] : fields
        values.slice(*names)
      end
      reader
    end
  end

  it 'preserves a fractional reader limit as a positive finite Top limit' do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'cpu.max'), "50000 100000\n")
      reader = OsCtl::Lib::CGroup::PathReader::V2.new(dir, '')
      state[:missing]['ct101/user-owned'] = { cpu_limit: reader.read_cpu_limit }
      partial.setup
      advance(partial)

      expect(row(partial.json_data, '101')).to include(cpu_limit: 50.0, cpu_limit_state: 'limited', errors: {})
    end
  end

  it 'emits the normative partial frame and independently preserves strict recovery' do
    allow(SecureRandom).to receive(:uuid).and_return('fixture-e')
    # The preceding five attempts are outside the fixture's observation window.
    partial.instance_variable_set(:@sequence, 5)
    partial.setup
    state[:missing]['ct102/user-owned'] = { memory: nil }
    advance(partial)
    example = JSON.parse(File.read(File.join(__dir__, 'fixtures/observation_memory_failure.json')))
    wire = JSON.parse(partial.json_data.to_json)
    expect(wire).not_to have_key('observation')
    expect(subset(wire, example)).to eq(example)

    state[:missing].clear
    advance(partial)
    expect(partial.data).to include(complete: false, invalid_reason: 'initial_baseline')
    expect(row(partial.data, '101')).to include(cpu_usage: 180.0, cpu_baseline_sequence: 7)
    expect(partial.json_data).to include(sequence: 8, measurement_window_started_monotonic_ns: nil)
    advance(partial)
    wire = partial.json_data
    expect(wire).to include(complete: true, sequence: 9, invalid_reason: nil, measurement_window_started_monotonic_ns: 130_000_000_000)
    expect(wire[:containers].map { |ct| ct[:id] }).to eq(%w[101 102 [host]])
    expect(wire[:containers].map { |ct| ct[:cpu_usage] }).to eq([180.0, 20.0, 100.0])
    expect(wire[:containers].map { |ct| ct[:loadavg].first }).to eq([12.0, 2.0, 20.0])
  end

  it 'measures known runs while a single inventory RPC is blocked, then resumes discovery' do
    partial.setup
    advance(partial)
    release = Queue.new
    requests = []
    allow(client).to receive(:cmd_data!).with(:ct_list, read_hostname: false) do
      requests << Thread.current
      release.pop if requests.one?
      state[:inventory].map(&:dup)
    end

    2.times do |i|
      state[:missing]['ct101/user-owned'] = { memory: 123 + i }
      Timeout.timeout(2) { advance(partial) }
      wire = partial.json_data
      expect(wire).to include(sequence: i + 3, complete: false, inventory_complete: false,
                              invalid_reason: 'inventory_pending', state_counts: nil)
      expect(row(wire, '101')).to include(run_verified: true, memory: 123 + i, cpu_usage: 180.0,
                                          cpu_baseline_sequence: i + 2)
    end
    expect(requests.size).to eq(1)
    state[:inventory].last.update(state: 'running', init_pid: 203, group_path: 'ct103/user-owned')
    state[:ticks][203] = 333
    state[:loads]['tank:103'] = [1, 1, 1]
    release << true
    expect(requests.first.join(2)).to eq(requests.first)
    advance(partial)
    expect(row(partial.json_data, '103')).to include(run_verified: true, cpu_usage: nil)
    advance(partial)
    expect(partial.json_data).to include(complete: true, inventory_complete: true)
  ensure
    release&.push(true)
    requests&.first&.join(2)
  end

  it 'keeps healthy cumulative origins and isolates run replacement and missing load' do
    partial.setup
    advance(partial)
    state[:ticks][202] += 1 # same numeric PID, different run
    state[:loads].delete('tank:102')
    advance(partial)
    expect(row(partial.data, '101')).to include(cpu_usage: 180.0)
    expect(row(partial.data, '102')).to include(run_verified: true, cpu_usage: nil, loadavg: nil)
    expect(row(partial.data, '[host]')[:cpu_usage]).to be_nil
    expect(partial.data[:inventory_complete]).to be(true)
    partial.mode = :cumulative
    expect(row(partial.data, '101')).to include(cpu_us: 54_000_000)
    expect(row(partial.data, '102')[:cpu_us]).to be_nil
    expect(row(partial.data, '[host]')[:cpu_us]).to be_nil
  end

  it 'keeps scheduled labels/rates but withholds endpoints dirtied by lifecycle events' do
    partial.setup
    monitor = partial.send(:monitor)
    state[:during] = lambda do
      monitor.send(:process_event, :ct_scheduled, pool: 'tank', id: '101', cpu_package_inuse: 2)
    end
    advance(partial)
    expect(partial.data).to include(inventory_complete: true, invalid_reason: 'inventory_changed')
    expect(row(partial.data, '101')).to include(cpu_usage: 180.0, cpu_package_inuse: 2)
    state[:during] = lambda do
      monitor.send(:process_event, :state, pool: 'tank', id: '102', state: 'stopped')
      monitor.send(:process_event, :state, pool: 'tank', id: '102', state: 'running', init_pid: 202)
    end
    advance(partial)
    expect(partial.data[:inventory_complete]).to be(false)
    expect(row(partial.data, '101')).to include(cpu_usage: 180.0)
    expect(row(partial.data, '102')).to include(run_verified: false, cpu_usage: nil, init_pid: nil, memory: nil)
  end

  it 'distinguishes missing/duplicate inventory from a verified empty population' do
    partial.setup
    state[:inventory] = [state[:inventory][0], state[:inventory][0]]
    advance(partial)
    expect(partial.data).to include(inventory_complete: false, state_counts: nil, invalid_reason: 'invalid_inventory')
    expect(partial.data[:containers].map { |ct| ct[:id] }).to eq(['[host]'])
    state[:inventory] = []
    advance(partial)
    expect(partial.data).to include(inventory_complete: true, state_counts: {}, invalid_reason: 'initial_baseline')
  end

  [[:init_pid, nil], [:group_path, nil], [:group_path, '']].each do |field, missing|
    it "keeps the running key and healthy peer when both endpoints lack #{field} (#{missing.inspect})" do
      partial.setup
      advance(partial)
      ct = state[:inventory][1]
      original = ct[field]
      missing.nil? ? ct.delete(field) : ct[field] = missing
      state[:proc_reads] = []
      2.times do |i|
        advance(partial)
        wire = partial.json_data
        expect(wire).to include(complete: false, invalid_reason: 'invalid_run', inventory_complete: false,
                                measurement_window_started_monotonic_ns: nil, state_counts: { 'running' => 2, 'stopped' => 1 })
        expect(wire[:containers].map { |item| item[:id] }).to eq(%w[101 102 [host]])
        expect(row(wire, '101')).to include(
          run_verified: true, cpu_usage: 180.0, cpu_baseline_sequence: i + 2, memory: 1_006_632_960, loadavg: [12.0, 7.0, 3.0]
        )
        expected_path = field == :group_path ? nil : ct[:group_path]
        expect(row(wire, '102')).to include(
          group_path: expected_path, run_verified: false, init_pid: nil, init_start_time_ticks: nil,
          cpu_usage: nil, cpu_baseline_sequence: nil, cpu_window_started_monotonic_ns: nil, memory: nil, nproc: nil,
          loadavg: nil, cpu_limit: nil, cpu_limit_state: 'unknown', memory_limit: nil,
          memory_limit_state: 'unknown', errors: { run: 'invalid_run' }
        )
        expect(row(wire, '[host]').values_at(:memory, :cpu_usage)).to eq([nil, nil])
        expect(partial.data[:node_totals]).to include(memory: 2_048_000_000, cpu_usage: a_kind_of(Numeric))
        expect(wire[:memory]).to include(used: 2_048_000_000)
        expect(partial.current_run?(row(wire, '102'))).to be(false)
      end
      expect(state[:proc_reads]).to eq([201] * 4)
      expect(OsCtl::Lib::CGroup::PathReader).to have_received(:new).exactly(10).times
      expect(OsCtl::Lib::CGroup::PathReader).to have_received(:new).with(anything, 'ct102/user-owned').twice
      partial.mode = :cumulative
      expect(row(partial.data, '101')).to include(cpu_us: 81_000_000)
      expect(row(partial.data, '102')[:cpu_us]).to be_nil
      expect(row(partial.data, '[host]')[:cpu_us]).to be_nil

      ct[field] = original
      advance(partial)
      warmup = partial.json_data
      expect(warmup).to include(complete: false, inventory_complete: true, invalid_reason: 'initial_baseline')
      expect(row(warmup, '101')).to include(cpu_usage: 180.0, cpu_baseline_sequence: 4)
      expect(row(warmup, '102')).to include(run_verified: true, cpu_usage: nil, memory: 250_000_000)
      advance(partial)
      expect(partial.json_data).to include(complete: true, inventory_complete: true)
      expect(row(partial.json_data, '102')).to include(cpu_usage: 20.0, cpu_baseline_sequence: 5)
    end
  end

  %i[init_pid group_path].each do |field|
    it "withholds a running row that loses #{field} at the final endpoint" do
      partial.setup
      state[:proc_reads] = []
      state[:during] = -> { state[:inventory][1][field] = nil }
      advance(partial)
      frame = partial.json_data
      expect(frame).to include(complete: false, inventory_complete: false, invalid_reason: 'invalid_run',
                               state_counts: { 'running' => 2, 'stopped' => 1 })
      expect(row(frame, '101')).to include(cpu_usage: 180.0, cpu_baseline_sequence: 1)
      expect(row(frame, '102')).to include(run_verified: false, init_pid: nil, loadavg: nil, errors: { run: 'invalid_run' })
      expect(state[:proc_reads]).to eq([201, 202, 201])
    end
  end

  it 'cannot use final-only run evidence to read a container or seed its CPU pair' do
    partial.setup
    state[:proc_reads] = []
    ct = state[:inventory][1]
    path = ct.delete(:group_path)
    state[:during] = -> { ct[:group_path] = path }
    advance(partial)
    wire = partial.json_data
    expect(wire).to include(complete: false, inventory_complete: false, invalid_reason: 'invalid_run')
    expect(row(wire, '101')).to include(cpu_usage: 180.0, cpu_baseline_sequence: 1)
    expect(row(wire, '102')).to include(group_path: path, run_verified: false, cpu_usage: nil, errors: { run: 'invalid_run' })
    expect(state[:proc_reads]).to eq([201, 201])
    advance(partial)
    expect(row(partial.json_data, '102')).to include(run_verified: true, cpu_usage: nil)
  end

  [nil, { id: '[host]' }, { pool: '' }, { state: 42 }].each do |malformed|
    it "fails the whole roster for malformed inventory #{malformed.inspect}" do
      partial.setup
      state[:proc_reads] = []
      state[:inventory] = malformed && [state[:inventory].first, state[:inventory][1].merge(malformed)]
      advance(partial)
      expect(partial.json_data).to include(complete: false, inventory_complete: false, state_counts: nil,
                                           invalid_reason: 'invalid_inventory')
      expect(partial.json_data[:containers].map { |item| item[:id] }).to eq(['[host]'])
      expect(state[:proc_reads]).to be_empty
    end
  end

  it 'recovers running membership without losing another run’s cumulative readings' do
    partial.setup
    advance(partial)
    new_ct = { pool: 'tank', id: '104', init_pid: 204, group_path: 'ct104/user-owned', state: 'running' }
    state[:inventory] << new_ct
    state[:ticks][204] = 250
    state[:loads]['tank:104'] = [0.0, 0.0, 0.0]
    advance(partial)
    frame = partial.data
    expect(frame).to include(inventory_complete: true, state_counts: { 'running' => 3, 'stopped' => 1 })
    expect(row(frame, '104')).to include(run_verified: true, cpu_usage: nil)
    expect(row(frame, '101')[:cpu_usage]).to eq(180.0)
    expect(row(frame, '[host]')[:cpu_usage]).to be_nil
    state[:inventory].delete(new_ct)
    advance(partial)
    expect(row(partial.data, '104')).to be_nil
    expect(row(partial.data, '[host]')[:cpu_usage]).to be_nil
    partial.mode = :cumulative
    expect(row(partial.data, '101')[:cpu_us]).to eq(81_000_000)
  end

  it 'revalidates a selected run without reacquiring or retimestamping the frame' do
    partial.setup
    advance(partial)
    frame = partial.data
    selected = row(frame, '101')
    expect(partial).not_to receive(:measure)
    expect(client).not_to receive(:cmd_data!)
    expect(partial.current_run?(selected)).to be(true)
    state[:ticks][201] += 1
    expect(partial.current_run?(selected)).to be(false)
    partial.mode = :cumulative
    expect(partial.data.slice(:sequence, :sample_completed_monotonic_ns)).to eq(frame.slice(:sequence, :sample_completed_monotonic_ns))
  end

  [
    { 'cgroup' => "0::/ct101/user-owned/lxc.payload.101\n" },
    { 'cgroup' => "0::/\n" },
    { 'cgroup' => "0::/ct102/user-owned/lxc.monitor.102\n" },
    { 'cgroup' => "0::/ct102/user-owned/lxc.payload.1020\n" },
    { 'status' => "NSpid:\t202\n" },
    { 'status' => "NSpid:\t202\t7\n" },
    { 'status' => "NSpid:\t202\t7\t1\n" },
    { 'stat' => "202 (dead) Z #{'0 ' * 18}23456\n" }
  ].each_with_index do |invalid, i|
    it "excludes an unproved owner without resetting a healthy peer (case #{i + 1})" do
      partial.setup
      advance(partial)
      selected = row(partial.data, '102')
      state[:proc] = { 202 => invalid }
      expect(partial.current_run?(selected)).to be(false)
      advance(partial)
      expect(partial.json_data).to include(complete: false, invalid_reason: 'invalid_run')
      expect(partial.json_data[:containers].map { |ct| ct[:id] }).to eq(%w[101 102 [host]])
      expect(partial.data).to include(inventory_complete: false, cpu: be_a(Hash), memory: be_a(Hash))
      expect(row(partial.data, '101')).to include(cpu_usage: 180.0, run_verified: true)
      expect(row(partial.data, '102')).to include(run_verified: false, init_pid: nil, init_start_time_ticks: nil,
                                                  cpu_usage: nil, loadavg: nil, memory: nil)
      expect(row(partial.data, '[host]').values_at(:cpu_usage, :memory)).to eq([nil, nil])
      state.delete(:proc)
      advance(partial)
      expect(partial.json_data[:invalid_reason]).to eq('initial_baseline')
      expect(row(partial.data, '101')[:cpu_usage]).to eq(180.0)
      expect(row(partial.data, '102')[:cpu_usage]).to be_nil
      advance(partial)
      expect(partial.json_data[:complete]).to be(true)
    end
  end

  it 'loses only load when a verified init changes cgroup namespace during acquisition' do
    partial.setup
    state[:during] = -> { state[:namespaces] = { 202 => 'cgroup:[999]' } }
    advance(partial)
    expect(partial.data).to include(inventory_complete: true, invalid_reason: 'missing_container_load')
    expect(row(partial.data, '102')).to include(run_verified: true, loadavg: nil, cpu_usage: 20.0)
    expect(row(partial.data, '101')[:loadavg]).to eq([12.0, 7.0, 3.0])
  end

  it 'withholds an owner lost at the second endpoint even after capturing its load' do
    partial.setup
    state[:during] = -> { state[:proc] = { 202 => { 'cgroup' => "0::/\n" } } }
    advance(partial)
    expect(partial.data[:inventory_complete]).to be(false)
    expect(row(partial.data, '102')).to include(run_verified: false, loadavg: nil)
    expect(row(partial.data, '101')[:cpu_usage]).to eq(180.0)
  end

  context 'with freezer-based cgroup v1 membership' do
    def v1 = true

    it 'uses exact freezer identity and rejects a conflicting resource hierarchy' do
      state[:proc] = { 202 => { 'cgroup' => "5:devices,freezer:/ct102/user-owned/lxc.payload.102/init.scope\n2:name=systemd:/\n" } }
      partial.setup
      advance(partial)
      expect(partial.json_data).to include(complete: true)
      state[:proc][202]['cgroup'] += "4:memory:/tank/ct.101/user-owned\n"
      advance(partial)
      expect(partial.data[:inventory_complete]).to be(false)
      expect(row(partial.data, '102')[:run_verified]).to be(false)
      expect(row(partial.data, '101')[:cpu_usage]).to eq(180.0)
    end
  end

  it 'publishes once while metadata arrives during every projection' do
    partial.setup
    projections = 0
    monitor = partial.send(:monitor)
    allow(partial).to receive(:project_partial).and_wrap_original do |original, *args|
      projections += 1
      expect(projections).to be <= 2
      val = original.call(*args)
      monitor.send(:process_event, :ct_scheduled, pool: 'tank', id: '101', cpu_package_inuse: projections)
      val
    end
    advance(partial)
    expect(projections).to eq(2)
    expect(partial.json_data).to include(sequence: 2, complete: false, invalid_reason: 'inventory_changed')
    expect(partial.json_data).to include(inventory_complete: true, measurement_window_started_monotonic_ns: nil)
    expect(row(partial.data, '101')).to include(cpu_usage: 180.0, cpu_package_inuse: 2)
    partial.mode = :cumulative
    expect(row(partial.data, '101')).to include(cpu_us: 27_000_000, cpu_package_inuse: 2)
  end

  it 'masks only the replaced run at the final lifecycle fence' do
    partial.setup
    monitor = partial.send(:monitor)
    allow(partial).to receive(:project_partial).and_wrap_original do |original, *args|
      original.call(*args).tap do
        monitor.send(:process_event, :ct_init_pid, pool: 'tank', id: '102', init_pid: 999)
      end
    end
    advance(partial)
    expect(partial.data).to include(inventory_complete: false, state_counts: nil)
    expect(row(partial.data, '101')).to include(cpu_usage: 180.0, run_verified: true)
    expect(row(partial.data, '102')).to include(cpu_usage: nil, run_verified: false, init_pid: nil, loadavg: nil)
    expect(partial.find_ct('tank', '102').init_pid).to eq(999)
    expect(row(partial.json_data, '[host]')[:cpu_usage]).to be_nil
  end

  context 'with network collection enabled' do
    let(:collectors) { { enable_netif: true, enable_zfs: false } }

    def netif_fixture
      stats = OsCtl::Lib::NetifStats.new
      allow(OsCtl::Lib::NetifStats).to receive(:new).and_return(stats)
      allow(stats).to receive(:list_netifs).and_return(%w[eth0 a b])
      allow(stats).to receive(:verified_stats) do |name|
        next nil if state[:missing_veth] == name

        v = ((state[:phase] + 1) * 100) + (state.fetch(:veth_birth, {}).fetch(name, 0) * 1000)
        [state.fetch(:veth_birth, {}).fetch(name, 0), { rx: { bytes: v, packets: v }, tx: { bytes: v, packets: v } }]
      end
    end

    it 'keeps failed bulk netif inventory unknown and recovers the affected nonempty catalog' do
      netif_fixture
      allow(client).to receive(:cmd_data!).with(:netif_list).and_raise(OsCtl::Client::Error)
      allow(client).to receive(:cmd_data!).with(:netif_list, pool: 'tank', id: '101').and_return([{ name: 'eth0', veth: 'a' }])
      allow(client).to receive(:cmd_data!).with(:netif_list, pool: 'tank', id: '103').and_return([])
      allow(client).to receive(:cmd_data!).with(:netif_list, pool: 'tank', id: '102') do
        raise OsCtl::Client::Error unless state[:phase] >= 2

        [{ name: 'eth0', veth: 'b' }]
      end
      partial.setup
      expect(partial.find_ct('tank', '102').netifs).to be_nil
      advance(partial)
      expect(row(partial.data, '101')[:tx][:bytes]).to be > 0
      expect(row(partial.data, '102')[:tx]).to be_nil
      expect(partial.data[:node_totals][:tx][:bytes]).to be > 0
      expect(row(partial.data, '[host]')[:tx]).to be_nil
      advance(partial)
      expect(partial.find_ct('tank', '102').netifs.map(&:veth)).to eq(['b'])
      expect(row(partial.data, '102')[:tx]).to be_nil
      advance(partial)
      expect(row(partial.data, '102')[:tx][:bytes]).to be > 0
      expect(client).to have_received(:cmd_data!).with(:netif_list, pool: 'tank', id: '101').once
    end

    it 'never joins a missing or recreated veth to the previous counters' do
      netif_fixture
      allow(client).to receive(:cmd_data!).with(:netif_list).and_return(
        [{ pool: 'tank', ctid: '101', name: 'eth0', veth: 'a' }, { pool: 'tank', ctid: '102', name: 'eth0', veth: 'b' }]
      )
      partial.setup
      advance(partial)
      state[:missing_veth] = 'b'
      advance(partial)
      expect(row(partial.data, '101')[:tx][:bytes]).to be > 0
      expect(row(partial.data, '102')[:tx]).to be_nil
      expect(row(partial.data, '[host]')[:tx]).to be_nil
      state.delete(:missing_veth)
      state[:veth_birth] = { 'b' => 1 }
      advance(partial)
      expect(row(partial.data, '102')[:tx]).to be_nil
      advance(partial)
      expect(row(partial.data, '102')[:tx][:bytes]).to be > 0
    end
  end

  context 'with ZFS collected and iostat disabled' do
    let(:collectors) { { enable_netif: false, enable_zfs: true, enable_iostat: false } }

    def dataset_stats(name)
      return if name && state[:missing_dataset] == name

      birth = state.fetch(:dataset_birth, {}).fetch(name, 0)
      value = ((state[:phase] + 1) * (name.nil? ? 600 : 100)) + (birth * 1000)
      stats = double(write_ios: value, read_ios: value, write_bytes: value, read_bytes: value)
      double(aggregate_stats: stats, source_id: birth)
    end

    it 'does not treat a missing or recreated dataset as a comparable zero endpoint' do
      state[:inventory].first(2).each { |attrs| attrs[:dataset] = "tank/#{attrs[:id]}" }
      allow(client).to receive(:cmd_data!).with(:pool_list).and_return([{ name: 'tank' }])
      allow(OsCtl::Cli::Top::ArcStats).to receive(:new).and_raise(Errno::ENOENT)
      allow(OsCtl::Lib::Zfs::ObjsetStats).to receive(:read_pools) do
        double(aggregate_stats: dataset_stats(nil).aggregate_stats).tap do |tree|
          allow(tree).to receive(:[]) { |name| dataset_stats(name) }
        end
      end
      partial.setup
      advance(partial)
      expect(row(partial.data, '102')[:zfsio][:bytes][:r]).to be > 0
      state[:missing_dataset] = 'tank/102'
      advance(partial)
      expect(row(partial.data, '102')[:zfsio]).to be_nil
      expect(row(partial.data, '[host]')[:zfsio]).to be_nil
      expect(row(partial.data, '101')[:zfsio][:bytes][:r]).to be > 0
      state.delete(:missing_dataset)
      state[:dataset_birth] = { 'tank/102' => 1 }
      advance(partial)
      expect(row(partial.data, '102')[:zfsio]).to be_nil
      advance(partial)
      expect(row(partial.data, '102')[:zfsio][:bytes][:r]).to be > 0
    end
  end

  it 'lets a vanished lookup recover without losing the still-subscribed stream' do
    partial.setup
    monitor = partial.send(:monitor)
    allow(client).to receive(:cmd_data!).with(:ct_show, pool: 'tank', id: 'gone', read_hostname: false).and_raise(OsCtl::Client::Error)
    monitor.send(:deliver, type: 'db', opts: { pool: 'tank', id: 'gone', object: 'container', action: 'add' })
    monitor.send(:deliver, type: 'ct_scheduled', opts: { pool: 'tank', id: '101', cpu_package_inuse: 7 })
    expect(partial.find_ct('tank', '101').cpu_package_inuse).to eq(7)
    advance(partial)
    expect(partial.json_data).to include(complete: true, inventory_complete: true)
    expect(row(partial.json_data, '101')[:cpu_usage]).to eq(180.0)
  end

  it 'fences monitor loss arriving at publication and does not recover on good inventory' do
    partial.setup
    chosen = row(partial.data, '101')
    allow(partial).to receive(:project_partial).and_wrap_original do |original, *args|
      original.call(*args).tap { partial.monitor_unavailable }
    end
    advance(partial)
    expect(partial.json_data).to include(sequence: 2, complete: false, invalid_reason: 'monitor_unavailable')
    expect(partial.data).to include(inventory_complete: false, state_counts: nil, memory: be_a(Hash))
    expect(row(partial.data, '101')).to include(cpu_usage: nil, run_verified: true, memory: 1_006_632_960)
    partial.monitor_ready
    advance(partial)
    expect(partial.json_data[:invalid_reason]).to eq('monitor_unavailable')
    expect(partial.current_run?(chosen)).to be(false)
  end

  it 'uses actual reader intervals for partial CPU but preserves strict numbers for a full wire frame' do
    allow(partial).to receive(:counter_clock).and_return(
      100_000_000_000, 101_000_000_000, 102_000_000_000, 103_000_000_000,
      115_000_000_000, 117_000_000_000, 120_000_000_000, 118_000_000_000,
      130_000_000_000, 132_000_000_000, 120_000_000_000, 133_000_000_000
    )
    partial.setup
    advance(partial)
    expect(partial.data[:complete]).to be(true)
    expect(row(partial.data, '101')[:cpu_usage]).not_to eq(180.0)
    expect(row(partial.json_data, '101')[:cpu_usage]).to eq(180.0)
    advance(partial)
    expect(partial.data).to include(complete: false, invalid_reason: 'invalid_window')
    expect(row(partial.data, '101')).to include(cpu_usage: nil, cpu_window_started_monotonic_ns: nil)
    expect(row(partial.data, '102')[:cpu_usage]).to be > 0
  end

  it 'cuts a reset CPU lineage and uses monotonic rates despite a backwards wall clock' do
    partial.setup
    advance(partial)
    state[:missing]['ct102/user-owned'] = { cpu_us: 0, cpu_user_hz: 0, cpu_system_hz: 0 }
    advance(partial)
    expect(partial.data[:invalid_reason]).to eq('counter_reset')
    expect(row(partial.data, '102')).to include(cpu_usage: nil, cpu_baseline_sequence: nil)
    state[:wall] = 1_000_000_000
    state[:missing].clear
    advance(partial)
    expect(partial.data[:invalid_reason]).to eq('invalid_window')
    expect(row(partial.data, '101')).to include(cpu_usage: 180.0)
  end
end
