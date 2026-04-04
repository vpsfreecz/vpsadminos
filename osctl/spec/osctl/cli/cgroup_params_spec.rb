# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsCtl::Cli::CGroupParams do
  let(:klass) do
    Class.new(OsCtl::Cli::Command) do
      include OsCtl::Cli::CGroupParams
    end
  end

  def cmd(args: [], opts: {}, gopts: {})
    build_command(klass, args:, opts:, gopts:)
  end

  it 'parses list options and adds the group column for --all' do
    command = cmd(
      args: ['ct1', 'cpu.weight'],
      opts: { version: '1', subsystem: 'cpu,memory', all: true, 'hide-header' => true }
    )

    expect(command).to receive(:osctld_fmt) do |_name, cmd_opts:, fmt_opts:|
      expect(cmd_opts).to eq(
        id: 'ct1',
        version: 1,
        parameters: ['cpu.weight'],
        subsystem: %w[cpu memory],
        all: true
      )
      expect(fmt_opts[:header]).to be(false)
      expect(fmt_opts[:cols].first).to eq(:group)
      expect(fmt_opts[:opts][:value][:display].call(%w[1024 max])).to include('1.0K', 'max')
    end

    command.do_cgparam_list(:ct_cgparam_list, id: 'ct1')
  end

  it 'rejects invalid cgroup versions' do
    expect do
      cmd(opts: { version: '3' }).do_cgparam_list(:ct_cgparam_list, id: 'ct1')
    end.to raise_error(GLI::BadCommandLine, "invalid cgroup version '3'")
  end

  it 'builds set and unset payloads from arguments' do
    set_command = cmd(args: %w[ct1 cpu.weight 1024], opts: { version: 2, append: true })
    unset_command = cmd(args: %w[ct1 cpu.weight], opts: { version: 2 })

    expect(set_command).to receive(:osctld_fmt).with(
      :ct_cgparam_set,
      cmd_opts: {
        id: 'ct1',
        parameters: [
          {
            version: 2,
            subsystem: 'cpu',
            parameter: 'cpu.weight',
            value: [1024]
          }
        ],
        append: true
      }
    )
    set_command.do_cgparam_set(:ct_cgparam_set, id: 'ct1')

    expect(unset_command).to receive(:osctld_fmt).with(
      :ct_cgparam_unset,
      cmd_opts: {
        id: 'ct1',
        parameters: [
          {
            version: 2,
            subsystem: 'cpu',
            parameter: 'cpu.weight'
          }
        ]
      }
    )
    unset_command.do_cgparam_unset(:ct_cgparam_unset, id: 'ct1')
  end

  it 'replaces parameters from stdin json' do
    command = cmd

    expect(command).to receive(:osctld_fmt).with(
      :ct_cgparam_replace,
      cmd_opts: {
        id: 'ct1',
        parameters: [{ 'parameter' => 'cpu.weight', 'value' => ['100'] }]
      }
    )

    with_stdin(JSON.generate('parameters' => [{ 'parameter' => 'cpu.weight', 'value' => ['100'] }])) do
      command.do_cgparam_replace(:ct_cgparam_replace, id: 'ct1')
    end
  end

  it 'builds cpu limit parameters for both cgroup versions' do
    command = cmd(args: %w[ct1 50], opts: { period: 100_000 })

    expect(command).to receive(:do_cgparam_set).with(
      :ct_cgparam_set,
      { id: 'ct1' },
      [
        { version: 2, subsystem: 'cpu', parameter: 'cpu.max', value: ['50000 100000'] },
        { version: 1, subsystem: 'cpu', parameter: 'cpu.cfs_period_us', value: [100_000] },
        { version: 1, subsystem: 'cpu', parameter: 'cpu.cfs_quota_us', value: [50_000] }
      ]
    )

    command.do_set_cpu_limit(:ct_cgparam_set, id: 'ct1')
  end

  it 'builds memory limit parameters with and without swap' do
    with_swap = cmd(args: %w[ct1 1G 512M])
    without_swap = cmd(args: %w[ct1 1G])

    expect(with_swap).to receive(:do_cgparam_set).with(
      :ct_cgparam_set,
      { id: 'ct1' },
      include(
        { version: 2, subsystem: 'memory', parameter: 'memory.max', value: [1_073_741_824] },
        { version: 2, subsystem: 'memory', parameter: 'memory.swap.max', value: [536_870_912] },
        { version: 1, subsystem: 'memory', parameter: 'memory.memsw.limit_in_bytes', value: [1_610_612_736] }
      )
    )
    with_swap.do_set_memory(:ct_cgparam_set, :ct_cgparam_unset, id: 'ct1')

    expect(without_swap).to receive(:do_cgparam_set).with(
      :ct_cgparam_set,
      { id: 'ct1' },
      include(
        { version: 2, subsystem: 'memory', parameter: 'memory.swap.max', value: ['0'] },
        { version: 1, subsystem: 'memory', parameter: 'memory.memsw.limit_in_bytes', value: [1_073_741_824] }
      )
    )
    without_swap.do_set_memory(:ct_cgparam_set, :ct_cgparam_unset, id: 'ct1')
  end

  it 'initializes cgroup subsystems from libosctl on v2' do
    command = cmd
    allow(OsCtl::Lib::CGroup).to receive(:v2?).and_return(true)

    command.cg_init_subsystems(double('client'))

    expect(command.instance_variable_get(:@cg_subsystems)).to eq(nil => OsCtl::Lib::CGroup::FS)
  end

  it 'initializes cgroup subsystems through the client on v1' do
    command = cmd
    client = instance_double(FakeClientHelpers::ClientDouble)
    allow(OsCtl::Lib::CGroup).to receive(:v2?).and_return(false)
    allow(client).to receive(:cmd_data!).with(:group_cgsubsystems).and_return(cpu: '/sys/fs/cgroup/cpu')

    command.cg_init_subsystems(client)

    expect(command.instance_variable_get(:@cg_subsystems)).to eq(cpu: '/sys/fs/cgroup/cpu')
  end

  it 'adds cgroup stats and raw params to hashes and arrays' do
    command = cmd
    command.instance_variable_set(:@cg_subsystems, { cpu: '/sys/fs/cgroup/cpu' })
    reader1 = instance_double(OsCtl::Lib::CGroup::PathReader, read_stats: { cpu_us: 10 }, read_params: { 'cpu.weight': '100' })
    reader2 = instance_double(OsCtl::Lib::CGroup::PathReader, read_stats: { cpu_us: 20 }, read_params: { 'cpu.weight': '200' })
    allow(OsCtl::Lib::CGroup::PathReader).to receive(:new).and_return(reader1, reader2)

    rows = [{ path: '/a' }, { path: '/b' }]

    expect(
      command.cg_add_stats(rows, ->(row) { row[:path] }, %i[cpu_us], true)
    ).to eq(
      [{ path: '/a', cpu_us: 10 }, { path: '/b', cpu_us: 20 }]
    )

    allow(OsCtl::Lib::CGroup::PathReader).to receive(:new).and_return(reader1, reader2)
    expect(
      command.cg_add_raw_cgroup_params(rows, ->(row) { row[:path] }, [:'cpu.weight'])
    ).to eq(
      [{ path: '/a', cpu_us: 10, 'cpu.weight': '100' }, { path: '/b', cpu_us: 20, 'cpu.weight': '200' }]
    )
  end

  it 'parses cgroup parameters and subsystem names' do
    command = cmd(opts: { cgparam: ['cpu.weight=100', 'memory.max=1G'] })

    expect(command.send(:parse_cgparams)).to eq(
      [
        { subsystem: 'cpu', parameter: 'cpu.weight', value: 100 },
        { subsystem: 'memory', parameter: 'memory.max', value: 1_073_741_824 }
      ]
    )
    expect(command.send(:parse_subsystem, 'cpu.weight')).to eq('cpu')
  end
end
