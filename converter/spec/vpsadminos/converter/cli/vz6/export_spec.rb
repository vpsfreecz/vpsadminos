# frozen_string_literal: true

require 'spec_helper'
require 'vpsadminos-converter/cli/vz6/export'
require 'vpsadminos-converter/exporter'
require 'vpsadminos-converter/container'
require 'vpsadminos-converter/vz6/container'

RSpec.describe VpsAdminOS::Converter::Cli::Vz6::Export do
  def export_opts(overrides = {})
    {
      consistent: true,
      compression: 'auto',
      zfs: false,
      'zfs-compressed-send' => false,
      'zfs-dataset' => nil,
      'zfs-subdir' => 'private',
      vpsadmin: false,
      'netif-type' => 'bridge',
      'netif-name' => 'eth0',
      'netif-hwaddr' => nil,
      'bridge-link' => 'lxcbr0'
    }.merge(overrides)
  end

  it 'validates export arguments' do
    command = build_command(described_class, args: ['101'], opts: export_opts)

    expect { command.export }.to raise_error(GLI::BadCommandLine, 'missing argument <file>')
  end

  it 'opens the output file, instantiates the exporter, dumps metadata/configs, and exports simfs' do
    with_tmpdir do |dir|
      path = File.join(dir, 'ct.tar')
      command = build_command(described_class, args: ['101', path], opts: export_opts)
      vz_ct = instance_double(VpsAdminOS::Converter::Vz6::Container, ploop?: false)
      target_ct = instance_double(VpsAdminOS::Converter::Container)
      exporter = instance_double(
        VpsAdminOS::Converter::Exporter::Tar,
        dump_metadata: nil,
        dump_configs: nil
      )
      exporter_class = class_double(VpsAdminOS::Converter::Exporter::Tar)

      expect(command).to receive(:convert_ct).with('101').and_return([vz_ct, target_ct])
      allow(command).to receive(:exporter_class).and_return(exporter_class)
      expect(exporter_class).to receive(:new) do |ct, io, options|
        expect(ct).to eq(target_ct)
        expect(io).to be_a(File)
        expect(options).to eq(
          compression: :auto,
          compressed_send: false
        )
        exporter
      end
      expect(exporter).to receive(:dump_metadata).with('full')
      expect(exporter).to receive(:dump_configs)
      expect(command).to receive(:export_tar_simfs).with(vz_ct, exporter)
      expect(command).to receive(:print_convert_status).with(vz_ct)

      command.export
    end
  end

  it 'dispatches to zfs stream export when zfs is enabled' do
    with_tmpdir do |dir|
      path = File.join(dir, 'ct.tar')
      command = build_command(described_class, args: ['101', path], opts: export_opts(zfs: true))
      vz_ct = instance_double(VpsAdminOS::Converter::Vz6::Container)
      target_ct = instance_double(VpsAdminOS::Converter::Container)
      exporter = instance_double(VpsAdminOS::Converter::Exporter::Zfs, dump_metadata: nil, dump_configs: nil)

      allow(command).to receive_messages(
        convert_ct: [vz_ct, target_ct],
        exporter_class: class_double(VpsAdminOS::Converter::Exporter::Zfs, new: exporter)
      )
      expect(command).to receive(:export_streams).with(vz_ct, exporter)
      allow(command).to receive(:print_convert_status)

      command.export
    end
  end

  it 'dispatches to ploop tar export for ploop containers' do
    with_tmpdir do |dir|
      path = File.join(dir, 'ct.tar')
      command = build_command(described_class, args: ['101', path], opts: export_opts)
      vz_ct = instance_double(VpsAdminOS::Converter::Vz6::Container, ploop?: true)
      target_ct = instance_double(VpsAdminOS::Converter::Container)
      exporter = instance_double(VpsAdminOS::Converter::Exporter::Tar, dump_metadata: nil, dump_configs: nil)

      allow(command).to receive_messages(
        convert_ct: [vz_ct, target_ct],
        exporter_class: class_double(VpsAdminOS::Converter::Exporter::Tar, new: exporter)
      )
      expect(command).to receive(:export_tar_ploop).with(vz_ct, exporter)
      allow(command).to receive(:print_convert_status)

      command.export
    end
  end

  it 'exports zfs streams and restarts running containers after the incremental dump' do
    command = build_command(described_class, opts: export_opts)
    vz_ct = instance_double(VpsAdminOS::Converter::Vz6::Container, ctid: '101', running?: true)
    exporter = instance_double(VpsAdminOS::Converter::Exporter::Zfs)

    expect(exporter).to receive(:dump_rootfs).and_yield
    expect(exporter).to receive(:dump_base).ordered
    expect(command).to receive(:syscmd).with('vzctl stop 101').ordered
    expect(exporter).to receive(:dump_incremental).ordered
    expect(command).to receive(:syscmd).with('vzctl start 101').ordered

    command.send(:export_streams, vz_ct, exporter)
  end

  it 'does not stop or restart when the container is not running or export is inconsistent' do
    command = build_command(described_class, opts: export_opts(consistent: false))
    vz_ct = instance_double(VpsAdminOS::Converter::Vz6::Container, running?: true)
    exporter = instance_double(VpsAdminOS::Converter::Exporter::Zfs)

    expect(exporter).to receive(:dump_rootfs).and_yield
    expect(exporter).to receive(:dump_base)
    expect(exporter).not_to receive(:dump_incremental)
    expect(command).not_to receive(:syscmd)

    command.send(:export_streams, vz_ct, exporter)
  end

  it 'restarts the container if incremental stream export fails after stopping it' do
    command = build_command(described_class, opts: export_opts)
    vz_ct = instance_double(VpsAdminOS::Converter::Vz6::Container, ctid: '101', running?: true)
    exporter = instance_double(VpsAdminOS::Converter::Exporter::Zfs)

    allow(exporter).to receive(:dump_rootfs).and_yield
    allow(exporter).to receive(:dump_base)
    expect(command).to receive(:syscmd).with('vzctl stop 101').ordered
    expect(exporter).to receive(:dump_incremental).and_raise('incremental failed').ordered
    expect(command).to receive(:syscmd).with('vzctl start 101').ordered

    expect do
      command.send(:export_streams, vz_ct, exporter)
    end.to raise_error(RuntimeError, 'incremental failed')
  end

  it 'handles ploop export for running mounted containers and restarts afterwards' do
    command = build_command(described_class, opts: export_opts)
    vz_ct = instance_double(
      VpsAdminOS::Converter::Vz6::Container,
      ctid: '101',
      status: { running: true, mounted: true }
    )
    exporter = instance_double(VpsAdminOS::Converter::Exporter::Tar, pack_rootfs: nil)

    expect(command).to receive(:syscmd).with('vzctl stop 101').ordered
    expect(command).to receive(:syscmd).with('vzctl mount 101').ordered
    expect(exporter).to receive(:pack_rootfs).ordered
    expect(command).to receive(:syscmd).with('vzctl start 101').ordered

    command.send(:export_tar_ploop, vz_ct, exporter)
  end

  it 'mounts and unmounts ploop containers that were initially unmounted' do
    command = build_command(described_class, opts: export_opts)
    vz_ct = instance_double(
      VpsAdminOS::Converter::Vz6::Container,
      ctid: '101',
      status: { running: false, mounted: false }
    )
    exporter = instance_double(VpsAdminOS::Converter::Exporter::Tar)

    expect(command).to receive(:syscmd).with('vzctl mount 101').ordered
    expect(exporter).to receive(:pack_rootfs).ordered
    expect(command).to receive(:syscmd).with('vzctl umount 101').ordered

    command.send(:export_tar_ploop, vz_ct, exporter)
  end

  it 'stops and restarts simfs exports when consistent export is requested' do
    command = build_command(described_class, opts: export_opts)
    vz_ct = instance_double(VpsAdminOS::Converter::Vz6::Container, ctid: '101', running?: true)
    exporter = instance_double(VpsAdminOS::Converter::Exporter::Tar)

    expect(command).to receive(:syscmd).with('vzctl stop 101').ordered
    expect(exporter).to receive(:pack_rootfs).and_raise('pack failed').ordered
    expect(command).to receive(:syscmd).with('vzctl start 101').ordered

    expect do
      command.send(:export_tar_simfs, vz_ct, exporter)
    end.to raise_error(RuntimeError, 'pack failed')
  end

  it 'does not stop simfs containers when consistent export is disabled' do
    command = build_command(described_class, opts: export_opts(consistent: false))
    vz_ct = instance_double(VpsAdminOS::Converter::Vz6::Container, running?: true)
    exporter = instance_double(VpsAdminOS::Converter::Exporter::Tar, pack_rootfs: nil)

    expect(command).not_to receive(:syscmd)

    command.send(:export_tar_simfs, vz_ct, exporter)
  end
end
