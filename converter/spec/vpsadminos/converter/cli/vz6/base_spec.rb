# frozen_string_literal: true

require 'spec_helper'
require 'vpsadminos-converter/cli/vz6/base'

RSpec.describe VpsAdminOS::Converter::Cli::Vz6::Base do
  def base_opts(overrides = {})
    {
      vpsadmin: false,
      zfs: false,
      'zfs-dataset' => nil,
      'zfs-subdir' => 'private',
      'zfs-compressed-send' => false,
      'netif-type' => 'bridge',
      'netif-name' => 'eth0',
      'netif-hwaddr' => nil,
      'bridge-link' => 'lxcbr0'
    }.merge(overrides)
  end

  it 'applies the vpsadmin preset and creates a zfs-backed target container' do
    command = build_command(described_class, opts: base_opts(vpsadmin: true))
    vz_ct = instance_double(
      VpsAdminOS::Converter::Vz6::Container,
      exist?: true,
      load: nil,
      ploop?: false
    )
    target_ct = OpenStruct.new

    allow(VpsAdminOS::Converter::Vz6::Container).to receive(:new).with('101').and_return(vz_ct)
    expect(vz_ct).to receive(:convert) do |_user, _group, opts|
      expect(opts).to eq(
        netif: {
          type: :routed,
          name: 'eth0',
          hwaddr: nil,
          link: 'lxcbr0'
        }
      )
      target_ct
    end

    _src, converted = command.send(:convert_ct, '101')

    expect(command.opts[:zfs]).to be(true)
    expect(command.opts['zfs-dataset']).to eq('vz/private/101')
    expect(command.opts['zfs-subdir']).to eq('private')
    expect(command.opts['netif-type']).to eq('routed')
    expect(command.opts['netif-name']).to eq('eth0')
    expect(converted.dataset).to be_a(OsCtl::Lib::Zfs::Dataset)
    expect(converted.dataset.name).to eq('vz/private/101')
    expect(converted.dataset.base).to eq('vz/private/101')
  end

  it 'rejects unsupported zfs subdirectories' do
    command = build_command(described_class, opts: base_opts(zfs: true, 'zfs-subdir' => 'root'))

    expect { command.send(:convert_ct, '101') }.to raise_error(
      RuntimeError,
      "unsupported configuration, only '--zfs-subdir private' is implemented"
    )
  end

  it 'raises when the source container does not exist' do
    command = build_command(described_class, opts: base_opts)
    vz_ct = instance_double(VpsAdminOS::Converter::Vz6::Container, exist?: false)

    allow(VpsAdminOS::Converter::Vz6::Container).to receive(:new).with('101').and_return(vz_ct)

    expect { command.send(:convert_ct, '101') }.to raise_error(RuntimeError, 'container not found')
  end

  it 'wraps parse failures in a clearer error message' do
    command = build_command(described_class, opts: base_opts)
    vz_ct = instance_double(
      VpsAdminOS::Converter::Vz6::Container,
      exist?: true,
      load: nil
    )

    allow(VpsAdminOS::Converter::Vz6::Container).to receive(:new).with('101').and_return(vz_ct)
    allow(vz_ct).to receive(:load).and_raise(RuntimeError, 'broken config')

    expect { command.send(:convert_ct, '101') }.to raise_error(
      RuntimeError,
      'unable to parse config: broken config'
    )
  end

  it 'rejects ploop containers when zfs conversion is requested' do
    command = build_command(described_class, opts: base_opts(zfs: true))
    vz_ct = instance_double(
      VpsAdminOS::Converter::Vz6::Container,
      exist?: true,
      load: nil,
      ploop?: true
    )

    allow(VpsAdminOS::Converter::Vz6::Container).to receive(:new).with('101').and_return(vz_ct)

    expect { command.send(:convert_ct, '101') }.to raise_error(
      RuntimeError,
      'container uses ploop, but ZFS was enabled'
    )
  end

  it 'passes the requested bridge netif mapping to conversion' do
    command = build_command(
      described_class,
      opts: base_opts(
        'netif-name' => 'eth1',
        'netif-hwaddr' => '00:11:22:33:44:55',
        'bridge-link' => 'br-test'
      )
    )
    vz_ct = instance_double(
      VpsAdminOS::Converter::Vz6::Container,
      exist?: true,
      load: nil,
      ploop?: false
    )
    target_ct = OpenStruct.new

    allow(VpsAdminOS::Converter::Vz6::Container).to receive(:new).with('101').and_return(vz_ct)
    expect(vz_ct).to receive(:convert) do |_user, _group, opts|
      expect(opts).to eq(
        netif: {
          type: :bridge,
          name: 'eth1',
          hwaddr: '00:11:22:33:44:55',
          link: 'br-test'
        }
      )
      target_ct
    end

    command.send(:convert_ct, '101')
  end

  it 'prints consumed and ignored config items' do
    command = build_command(described_class, opts: base_opts)
    item1 = instance_double(VpsAdminOS::Converter::Vz6::ConfigItem, consumed?: true, key: 'HOSTNAME', value: 'demo')
    item2 = instance_double(VpsAdminOS::Converter::Vz6::ConfigItem, consumed?: false, key: 'UNUSED', value: 'x')
    vz_ct = instance_double(VpsAdminOS::Converter::Vz6::Container, config: [item1, item2])

    output = capture_stdout { command.send(:print_convert_status, vz_ct) }

    expect(output).to include('Consumed config items:')
    expect(output).to include('HOSTNAME = "demo"')
    expect(output).to include('Ignored config items:')
    expect(output).to include('UNUSED = "x"')
  end

  it 'returns the matching exporter class for tar and zfs exports' do
    tar_command = build_command(described_class, opts: base_opts)
    zfs_command = build_command(described_class, opts: base_opts(zfs: true))

    expect(tar_command.send(:exporter_class)).to eq(VpsAdminOS::Converter::Exporter::Tar)
    expect(zfs_command.send(:exporter_class)).to eq(VpsAdminOS::Converter::Exporter::Zfs)
  end
end
