# frozen_string_literal: true

require 'spec_helper'
require 'vpsadminos-converter/cli'

RSpec.describe VpsAdminOS::Converter::Cli::App do
  it 'passes the export defaults to the command object' do
    command = instance_double(VpsAdminOS::Converter::Cli::Vz6::Export, export: nil)
    allow(VpsAdminOS::Converter::Cli::Vz6::Export).to receive(:new) do |_gopts, opts, args|
      expect(opts[:consistent]).to be(true)
      expect(opts[:compression]).to eq('auto')
      expect(args).to eq(%w[101 out.tar])
      command
    end

    app = described_class.new
    app.setup

    expect { app.run(%w[vz6 export 101 out.tar]) }.not_to raise_error
  end

  it 'forwards migrate stage options to the command object' do
    command = instance_double(VpsAdminOS::Converter::Cli::Vz6::Migrate, stage: nil)
    allow(VpsAdminOS::Converter::Cli::Vz6::Migrate).to receive(:new) do |_gopts, opts, args|
      expect(opts[:port]).to eq(2222)
      expect(opts[:zfs]).to be(true)
      expect(opts['zfs-dataset']).to eq('tank/ct/101')
      expect(opts['zfs-subdir']).to eq('private')
      expect(opts['zfs-compressed-send']).to be(true)
      expect(opts['netif-type']).to eq('routed')
      expect(opts['netif-name']).to eq('eth1')
      expect(opts['netif-hwaddr']).to eq('00:11:22:33:44:55')
      expect(opts['bridge-link']).to eq('br0')
      expect(args).to eq(%w[101 node.example])
      command
    end

    app = described_class.new
    app.setup

    expect do
      app.run(
        %w[
          vz6 migrate stage
          --port 2222
          --zfs
          --zfs-dataset tank/ct/101
          --zfs-subdir private
          --zfs-compressed-send
          --netif-type routed
          --netif-name eth1
          --netif-hwaddr 00:11:22:33:44:55
          --bridge-link br0
          101 node.example
        ]
      )
    end.not_to raise_error
  end

  it 'passes the current migrate now defaults to the command object' do
    command = instance_double(VpsAdminOS::Converter::Cli::Vz6::Migrate, now: nil)
    allow(VpsAdminOS::Converter::Cli::Vz6::Migrate).to receive(:new) do |_gopts, opts, args|
      expect(opts[:proceed]).to be(false)
      expect(opts[:delete]).to be(false)
      expect(args).to eq(%w[101 node.example])
      command
    end

    app = described_class.new
    app.setup

    expect { app.run(%w[vz6 migrate now 101 node.example]) }.not_to raise_error
  end

  it 'invokes man with the expected manpath' do
    app = described_class.new
    app.setup
    manpath = File.realpath(File.join(__dir__, '..', '..', '..', '..', 'man'))

    expect(app).to receive(:system).with("man -M #{manpath} vpsadminos-convert")

    app.run(%w[man])
  end
end
