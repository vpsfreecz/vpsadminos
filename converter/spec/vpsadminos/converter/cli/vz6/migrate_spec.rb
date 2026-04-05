# frozen_string_literal: true

require 'spec_helper'
require 'vpsadminos-converter/cli/vz6/migrate'
require 'vpsadminos-converter/container'
require 'vpsadminos-converter/vz6/container'
require 'vpsadminos-converter/vz6/migrator/simfs'

RSpec.describe VpsAdminOS::Converter::Cli::Vz6::Migrate do
  def migrate_opts(overrides = {})
    {
      port: nil,
      delete: false,
      proceed: false,
      zfs: false,
      'zfs-dataset' => nil,
      'zfs-subdir' => 'private',
      'zfs-compressed-send' => false,
      vpsadmin: false,
      'netif-type' => 'bridge',
      'netif-name' => 'eth0',
      'netif-hwaddr' => nil,
      'bridge-link' => 'lxcbr0',
      force: false
    }.merge(overrides)
  end

  it 'validates stage arguments, creates the migrator, and prints success guidance' do
    command = build_command(described_class, args: %w[101 node.example], opts: migrate_opts(port: 2222))
    vz_ct = instance_double(VpsAdminOS::Converter::Vz6::Container)
    target_ct = instance_double(VpsAdminOS::Converter::Container)
    migrator = instance_double(VpsAdminOS::Converter::Vz6::Migrator::Simfs, stage: nil)

    expect(command).to receive(:convert_ct).with('101').and_return([vz_ct, target_ct])
    expect(VpsAdminOS::Converter::Vz6::Migrator).to receive(:create) do |src, dst, options|
      expect(src).to eq(vz_ct)
      expect(dst).to eq(target_ct)
      expect(options).to eq(
        dst: 'node.example',
        port: 2222,
        zfs: false,
        zfs_dataset: nil,
        zfs_subdir: 'private',
        zfs_compressed_send: false
      )
    end.and_return(migrator)
    expect(command).to receive(:print_convert_status).with(vz_ct)

    output = capture_stdout { command.stage }

    expect(output).to include('Migration stage successful')
    expect(output).to include('Continue with vz6 migrate sync')
  end

  %i[sync transfer cleanup cancel].each do |command_name|
    it "keeps strict validation for direct #{command_name} calls" do
      command = build_command(described_class, args: %w[101 extra], opts: migrate_opts)

      expect { command.public_send(command_name) }.to raise_error(
        GLI::BadCommandLine,
        'unknown argument: extra'
      )
    end
  end

  it 'loads the migrator for sync and passes the progress callback' do
    command = build_command(described_class, args: ['101'], opts: migrate_opts)
    migrator = instance_double(VpsAdminOS::Converter::Vz6::Migrator::Simfs, can_proceed?: true)

    expect(VpsAdminOS::Converter::Vz6::Migrator).to receive(:load).with('101').and_return(migrator)
    expect(migrator).to receive(:sync) do |&block|
      expect(block).to be_a(Proc)
    end

    command.sync
  end

  it 'loads the migrator for cleanup and enforces the sequence' do
    command = build_command(described_class, args: ['101'], opts: migrate_opts(delete: true))
    migrator = instance_double(
      VpsAdminOS::Converter::Vz6::Migrator::Simfs,
      can_proceed?: true,
      cleanup: nil
    )

    expect(VpsAdminOS::Converter::Vz6::Migrator).to receive(:load).with('101').and_return(migrator)
    expect(migrator).to receive(:cleanup).with(command.opts)

    command.cleanup
  end

  it 'raises when the requested migration step cannot proceed' do
    command = build_command(described_class, args: ['101'], opts: migrate_opts)
    migrator = instance_double(VpsAdminOS::Converter::Vz6::Migrator::Simfs, can_proceed?: false)

    allow(VpsAdminOS::Converter::Vz6::Migrator).to receive(:load).with('101').and_return(migrator)

    expect { command.transfer }.to raise_error(RuntimeError, 'invalid migration sequence')
  end

  it 'runs now through stage, sync, transfer, and cleanup on the same command instance' do
    command = build_command(described_class, args: %w[101 node.example], opts: migrate_opts(proceed: true))

    expect(command).to receive(:stage).ordered
    expect(command).to receive(:perform_sync).with('101').ordered
    expect(command).to receive(:perform_transfer).with('101').ordered
    expect(command).to receive(:perform_cleanup).with('101').ordered

    expect { command.now }.not_to raise_error
  end

  it 'proceeds with now when the user confirms interactively' do
    command = build_command(described_class, args: %w[101 node.example], opts: migrate_opts)

    allow(command).to receive(:stage)
    expect(command).to receive(:perform_sync).with('101')
    expect(command).to receive(:perform_transfer).with('101')
    expect(command).to receive(:perform_cleanup).with('101')

    output = with_stdin("y\n") { capture_stdout { command.now } }

    expect(output).to include('Do you wish to continue? [y/N]: ')
  end

  it 'cancels now cleanly when the user declines to proceed' do
    command = build_command(described_class, args: %w[101 node.example], opts: migrate_opts)

    allow(command).to receive(:stage)
    expect(command).to receive(:perform_cancel).with('101')
    expect(command).not_to receive(:perform_sync)
    expect(command).not_to receive(:perform_transfer)
    expect(command).not_to receive(:perform_cleanup)

    expect do
      with_stdin("n\n") { command.now }
    end.not_to raise_error
  end

  it 'prints step progress and updates transfer progress' do
    command = build_command(described_class, opts: migrate_opts)
    pb = instance_double(ProgressBar::Base, finish: nil)
    command.instance_variable_set(:@pb, pb)

    expect(pb).to receive(:finish)
    output = capture_stdout { command.send(:progress, :step, 'Syncing /') }
    expect(output).to include('> Syncing /')

    expect(command).to receive(:progressbar_update).with(100, 20)
    command.send(:progress, :transfer, [100, 20])
  end

  it 'allows progressbar_done to be called when no bar exists' do
    command = build_command(described_class, opts: migrate_opts)

    expect { command.send(:progressbar_done) }.not_to raise_error
  end
end
