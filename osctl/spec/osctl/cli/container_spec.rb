# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsCtl::Cli::Container do
  def cmd(args: [], opts: {}, gopts: {})
    build_command(described_class, args:, opts:, gopts:)
  end

  it 'initializes cgroup subsystems in bisect using the open client connection' do
    client = FakeClientHelpers::ClientDouble.new(
      cmd_data: { ct_list: [[{ pool: 'tank', id: 'ct1', group_path: '/grp', state: 'running' }]] }
    )
    bisect = instance_double(OsCtl::Cli::Bisect, run: nil)
    command = cmd(
      opts: {
        action: 'freeze',
        output: nil,
        sort: nil,
        exclude: nil,
        ephemeral: false,
        persistent: false
      }
    )

    expect(command).to receive(:cg_init_subsystems).with(client)
    allow(command).to receive_messages(osctld_open: client, cg_list_raw_cgroup_params: [])
    expect(command).to receive(:cg_add_stats) { |data, *_args| data }
    expect(command).to receive(:add_loadavgs).with(kind_of(Array))
    expect(command).to receive(:cg_add_raw_cgroup_params) { |data, *_args| data }
    expect(OsCtl::Cli::Bisect).to receive(:new) do |cts, suspend_action:, cols:|
      expect(cts).to eq([{ pool: 'tank', id: 'ct1', group_path: '/grp', state: 'running' }])
      expect(suspend_action).to eq(:freeze)
      expect(cols).to be_a(Array)
    end.and_return(bisect)

    command.bisect
  end

  it 'dispatches device_promote to the promote helper without requiring a mode argument' do
    command = cmd(args: %w[ct1 char 1 3], gopts: { pool: 'tank' })

    expect(command).to receive(:do_device_promote).with(
      :ct_device_promote,
      id: 'ct1',
      pool: 'tank'
    )
    expect(command).not_to receive(:do_device_chmod)

    command.device_promote
  end

  it 'builds remote-image create payloads with defaults and zfs properties' do
    command = cmd(
      args: ['ct1'],
      opts: { distribution: 'debian', 'zfs-property' => ['quota=1G'] },
      gopts: { pool: 'tank' }
    )
    stub_backticks(command, 'uname -m' => "x86_64\n")

    expect(command).to receive(:osctld_fmt).with(
      :ct_create,
      cmd_opts: {
        id: 'ct1',
        pool: 'tank',
        user: nil,
        repository: nil,
        zfs_properties: { 'quota' => '1G' },
        image: {
          vendor: 'default',
          variant: 'default',
          arch: 'x86_64',
          distribution: 'debian',
          version: 'stable'
        }
      }
    )

    command.send(:create_with_remote_image)
  end

  it 'requires distribution, version, and arch for empty creates' do
    expect { cmd(args: ['ct1']).send(:create_empty) }.to raise_error(GLI::BadCommandLine, 'provide --distribution')
    expect { cmd(args: ['ct1'], opts: { distribution: 'debian' }).send(:create_empty) }.to raise_error(GLI::BadCommandLine, 'provide --version')
    expect { cmd(args: ['ct1'], opts: { distribution: 'debian', version: '12' }).send(:create_empty) }.to raise_error(GLI::BadCommandLine, 'provide --arch')
  end

  it 'builds empty create payloads' do
    command = cmd(args: ['ct1'], opts: { distribution: 'debian', version: '12', arch: 'x86_64', group: 'grp' }, gopts: { pool: 'tank' })

    expect(command).to receive(:osctld_fmt).with(
      :ct_create_empty,
      cmd_opts: {
        id: 'ct1',
        pool: 'tank',
        user: nil,
        distribution: 'debian',
        version: '12',
        arch: 'x86_64',
        group: 'grp'
      }
    )

    command.send(:create_empty)
  end

  it 'computes wait values for strings, infinity, foreground, and invalid input' do
    expect(cmd.send(:get_ct_wait, 'infinity')).to eq('infinity')
    expect(cmd.send(:get_ct_wait, '5')).to eq(5)
    expect(cmd.send(:get_ct_wait, '0')).to be(false)
    expect(cmd(opts: { foreground: true }).send(:get_ct_wait, '10')).to be(false)
    expect { cmd.send(:get_ct_wait, '-1') }.to raise_error(GLI::BadCommandLine, 'invalid value for --wait')
    expect { cmd.send(:get_ct_wait, 'abc') }.to raise_error(GLI::BadCommandLine, 'invalid value for --wait')
  end

  it 'adds load averages for running containers and tolerates reader failures' do
    running = { pool: 'tank', id: 'ct1', state: 'running' }
    stopped = { pool: 'tank', id: 'ct2', state: 'stopped' }
    allow(OsCtl::Lib::LoadAvgReader).to receive(:read_for).and_return(
      'tank:ct1' => double(averages: [0.1, 0.2, 0.3])
    )

    cmd.send(:add_loadavgs, [running, stopped])
    expect(running[:loadavg]).to eq([0.1, 0.2, 0.3])
    expect(stopped[:loadavg]).to be_nil

    allow(OsCtl::Lib::LoadAvgReader).to receive(:read_for).and_raise(Errno::ENOENT)
    out, err = capture_output { cmd.send(:add_loadavg, running) }
    expect(out).to eq('')
    expect(err).to include('Unable to read container load averages')
  end

  it 'maps exec responses to errors and custom exits' do
    command = cmd
    error_client = instance_double(FakeClientHelpers::ClientDouble, receive_resp: client_response(status: false, message: 'boom'))
    exit_client = instance_double(FakeClientHelpers::ClientDouble, receive_resp: client_response(status: true, response: { exitstatus: 5 }))

    expect { command.send(:handle_exec_response, error_client) }.to raise_error('boom')
    expect { command.send(:handle_exec_response, exit_client) }.to raise_error(GLI::CustomExit)
  end

  it 'filters invalid ugids and warns about discarded values' do
    command = cmd

    _out, err = capture_output do
      expect(command.send(:filter_ugids, ['1000', 'abc', '-1', ' 42 '])).to eq([1000, 42])
    end

    expect(err).to include('Ignoring "abc"', 'Ignoring "-1"')
  end

  it 'uses read_hostname for list and show when hostname_readout is selected' do
    list_client = FakeClientHelpers::ClientDouble.new(cmd_data: { ct_list: [[{ pool: 'tank', id: 'ct1', group_path: '/grp', state: 'stopped' }]] })
    show_client = FakeClientHelpers::ClientDouble.new(cmd_data: { ct_show: [{ pool: 'tank', id: 'ct1', group_path: '/grp', state: 'stopped' }] })
    zfsprops = instance_double(OsCtl::Cli::ZfsProperties, list_property_names: [], validate_property_names: [:hostname_readout], add_container_values: nil)
    keyring = instance_double(OsCtl::Cli::KernelKeyring, list_param_names: [], add_container_values: nil)

    allow(OsCtl::Cli::ZfsProperties).to receive(:new).and_return(zfsprops)
    allow(OsCtl::Cli::KernelKeyring).to receive(:new).and_return(keyring)

    list_command = cmd(opts: { output: 'hostname_readout' })
    allow(list_command).to receive(:cg_init_subsystems)
    allow(list_command).to receive_messages(osctld_open: list_client, cg_list_raw_cgroup_params: [])
    allow(list_command).to receive(:cg_add_stats) { |data, *_| data }
    allow(list_command).to receive(:add_loadavgs)
    allow(list_command).to receive(:cg_add_raw_cgroup_params) { |data, *_| data }
    allow(list_command).to receive(:format_output)
    list_command.list
    expect(list_client.calls).to include([:cmd_data!, :ct_list, { read_hostname: true }])

    show_command = cmd(args: ['ct1'], opts: { output: 'hostname_readout' })
    allow(show_command).to receive(:cg_init_subsystems)
    allow(show_command).to receive_messages(osctld_open: show_client, cg_list_raw_cgroup_params: [])
    allow(show_command).to receive(:cg_add_stats) { |data, *_| data }
    allow(show_command).to receive(:add_loadavg)
    allow(show_command).to receive(:cg_add_raw_cgroup_params) { |data, *_| data }
    allow(show_command).to receive(:format_output)
    show_command.show
    expect(show_client.calls).to include([:cmd_data!, :ct_show, { id: 'ct1', pool: nil, read_hostname: true }])
  end

  it 'dispatches copy actions through with_progress' do
    {
      copy: [:ct_copy, %w[ct1 dozer:ct2], { consistent: true, restart: false }],
      copy_config: [:ct_copy_config, %w[ct1 dozer:ct2], {}],
      copy_rootfs: [:ct_copy_rootfs, ['ct1'], {}],
      copy_sync: [:ct_copy_sync, ['ct1'], {}],
      copy_state: [:ct_copy_state, ['ct1'], { consistent: false, restart: true }],
      copy_cleanup: [:ct_copy_cleanup, ['ct1'], {}],
      copy_cancel: [:ct_copy_cancel, ['ct1'], {}]
    }.each do |method_name, (osctld_cmd, args, opts)|
      command = cmd(args:, opts: { 'network-interfaces' => true }.merge(opts), gopts: { pool: 'tank' })

      expect(command).to receive(:with_progress)
        .with(osctld_cmd, hash_including(pool: 'tank', id: 'ct1'))
      command.public_send(method_name)
    end
  end

  it 'passes from snapshot to copy config' do
    command = cmd(
      args: %w[ct1 dozer:ct2],
      opts: { 'from-snapshot' => 'vpsadmin-replace' },
      gopts: { pool: 'tank' }
    )

    expect(command).to receive(:with_progress).with(
      :ct_copy_config,
      hash_including(from_snapshot: 'vpsadmin-replace')
    )
    command.copy_config
  end

  it 'parses copy targets and forwards state options' do
    command = cmd(
      args: %w[ct1 dozer:ct2],
      opts: {
        user: 'bob',
        group: 'web',
        dataset: 'dozer/custom/ct2',
        consistent: false,
        restart: false,
        'network-interfaces' => false
      },
      gopts: { pool: 'tank' }
    )

    expect(command).to receive(:with_progress).with(
      :ct_copy,
      hash_including(
        pool: 'tank',
        id: 'ct1',
        target_pool: 'dozer',
        target_id: 'ct2',
        target_user: 'bob',
        target_group: 'web',
        target_dataset: 'dozer/custom/ct2',
        network_interfaces: false,
        consistent: false,
        restart: false
      )
    )

    command.copy
  end

  it 'dispatches move actions through with_progress' do
    {
      move: [:ct_move, %w[ct1 dozer:ct2], { start: false }],
      move_config: [:ct_move_config, %w[ct1 dozer:ct2], {}],
      move_rootfs: [:ct_move_rootfs, ['ct1'], {}],
      move_sync: [:ct_move_sync, ['ct1'], {}],
      move_state: [:ct_move_state, ['ct1'], { start: false }],
      move_cleanup: [:ct_move_cleanup, ['ct1'], {}],
      move_cancel: [:ct_move_cancel, ['ct1'], {}]
    }.each do |method_name, (osctld_cmd, args, opts)|
      command = cmd(args:, opts:, gopts: { pool: 'tank' })

      expect(command).to receive(:with_progress)
        .with(osctld_cmd, hash_including(pool: 'tank', id: 'ct1'))
      command.public_send(method_name)
    end
  end

  it 'keeps move targets on the source pool when no target pool is provided' do
    command = cmd(
      args: %w[ct1 ct2],
      opts: { start: true },
      gopts: { pool: 'tank' }
    )

    expect(command).to receive(:with_progress).with(
      :ct_move,
      hash_including(
        pool: 'tank',
        id: 'ct1',
        target_pool: nil,
        target_id: 'ct2',
        network_interfaces: true,
        start: true
      )
    )

    command.move
  end

  it 'parses target pool options and forwards start' do
    command = cmd(
      args: %w[ct1 ct2],
      opts: { pool: 'dozer', start: true },
      gopts: { pool: 'tank' }
    )

    expect(command).to receive(:with_progress).with(
      :ct_move,
      hash_including(
        pool: 'tank',
        id: 'ct1',
        target_pool: 'dozer',
        target_id: 'ct2',
        network_interfaces: true,
        start: true
      )
    )

    command.move
  end
end
