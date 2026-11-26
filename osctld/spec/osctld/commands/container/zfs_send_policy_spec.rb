# frozen_string_literal: true

require 'stringio'
require 'osctld/config'
require 'osctld/command'
require 'osctld/exceptions'
require 'osctld/commands/container/export'
require 'osctld/commands/container/send_rootfs'
require 'osctld/commands/container/send_sync'
require 'osctld/commands/container/send_state'
require 'osctld/commands/container/local_transfer/base'
require 'osctld/utils/switch_user'
require 'osctld/container/dataset_builder'

RSpec.describe OsCtld::Config::Zfs::Send do
  def stub_policy(compressed)
    policy = OsCtld::Config::Zfs.new('send' => { 'compressed' => compressed })
    config = instance_double(OsCtld::Config, zfs: policy)
    daemon = Struct.new(:config).new(config)
    stub_const('OsCtld::Daemon', Class.new do
      def self.get; end
    end)
    allow(OsCtld::Daemon).to receive(:get).and_return(daemon)
  end

  def remote_container
    options = Struct.new(:snapshots).new(false)
    log = Struct.new(:opts, :snapshots).new(options, %w[previous base])
    Struct.new(:send_log).new(log)
  end

  [true, false].each do |compressed|
    context "with compressed sends #{compressed}" do
      before do
        stub_policy(compressed)
      end

      [
        [OsCtld::Commands::Container::SendRootfs, :send_snapshot],
        [OsCtld::Commands::Container::SendSync, :send_dataset],
        [OsCtld::Commands::Container::SendState, :send_dataset]
      ].each do |command_class, method|
        it "selects compression without changing snapshot flags in #{command_class}" do
          command = command_class.new({}, {})
          ct = remote_container
          dataset = OsCtl::Lib::Zfs::Dataset.new('tank/ct/data', base: 'tank/ct')
          streams = []
          allow(command).to receive(:progress)
          allow(OsCtl::Lib::Zfs::Stream).to receive(:new).and_wrap_original do |original, *args, **opts|
            stream = original.call(*args, **opts)
            streams << stream
            # Stop after constructing the real stream, before any processes run.
            allow(stream).to receive(:progress).and_raise(StopIteration)
            stream
          end

          expect do
            if method == :send_snapshot
              command.send(method, ct, dataset, 'base', 'base', 'previous')
            else
              command.send(method, ct, dataset, 'state')
            end
          end.to raise_error(StopIteration)

          target = method == :send_snapshot ? 'base' : 'state'
          from = command_class == OsCtld::Commands::Container::SendState ? 'base' : 'previous'
          prefix = compressed ? 'zfs send -c -p -L' : 'zfs send -p -L'
          expect(streams.fetch(0).send(:full_zfs_send_cmd)).to eq(
            "#{prefix} -v -i @#{from} tank/ct/data@#{target}"
          )
        end
      end

      it 'selects compression for local copies while retaining direct incremental sends' do
        command = OsCtld::Commands::Container::LocalTransfer::Base.new({}, {})
        pair = Struct.new(:source, :target, :relative_name).new('tank/ct', 'other/ct', '/')
        streams = []
        allow(command).to receive(:progress)
        allow(OsCtl::Lib::Zfs::Stream).to receive(:new).and_wrap_original do |original, *args, **opts|
          stream = original.call(*args, **opts)
          streams << stream
          allow(stream).to receive(:send_recv)
          stream
        end

        command.send(:transfer_dataset, pair, 'new', from_snapshot: 'old')

        prefix = compressed ? 'zfs send -c -p -L' : 'zfs send -p -L'
        expect(streams.fetch(0).send(:full_zfs_send_cmd)).to eq("#{prefix} -v -i @old tank/ct@new")
        expect(streams.fetch(0)).to have_received(:send_recv).with('other/ct')
      end

      %i[auto gzip off].each do |compression|
        it "passes the policy to exports while preserving outer #{compression} compression" do
          ct = Struct.new(:state).new(:stopped)
          io = StringIO.new
          command = OsCtld::Commands::Container::Export.new({ compression: compression.to_s }, {})
          exporter = instance_double(OsCtl::Lib::Exporter::Zfs)
          hook_manager = Class.new do
            def self.list_all_scripts(_ct); end
          end
          stub_const('OsCtld::Hook::Manager', hook_manager)
          allow(OsCtld::Hook::Manager).to receive(:list_all_scripts).and_return([])
          allow(OsCtl::Lib::Exporter::Zfs).to receive(:new).and_return(exporter)
          allow(exporter).to receive(:dump_metadata)
          allow(exporter).to receive(:dump_configs)
          allow(exporter).to receive(:dump_user_hook_scripts)
          allow(exporter).to receive(:dump_rootfs).and_yield
          allow(exporter).to receive(:dump_base)
          allow(exporter).to receive(:close)

          command.send(:export, ct, io)

          expect(OsCtl::Lib::Exporter::Zfs).to have_received(:new).with(
            ct, io, compression: compression, compressed_send: compressed
          )
        end
      end

      [nil, 'old'].each do |from|
        it "selects compression for the dataset builder with base #{from.inspect}" do
          builder = OsCtld::Container::DatasetBuilder.new
          dataset = OsCtl::Lib::Zfs::Dataset.new('tank/ct', base: 'tank/ct')
          allow(Time).to receive(:now).and_return(Time.at(123))
          allow(builder).to receive(:zfs)
          allow(builder).to receive(:syscmd)

          snapshot = builder.copy_datasets([dataset], ['other/ct'], from: from)

          flags = compressed ? '-p -L -c' : '-p -L'
          incremental = from ? '-i @old' : ''
          expect(builder).to have_received(:syscmd).with(
            "zfs send #{flags} #{incremental} tank/ct@#{snapshot} | zfs recv -F other/ct"
          )
        end
      end
    end
  end
end
