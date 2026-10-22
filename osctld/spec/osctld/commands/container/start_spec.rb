# frozen_string_literal: true

require 'osctld/exceptions'
require 'osctld/command'
require 'osctld/promise'
require 'osctld/process_identity'
require 'osctld/container/run_id'
require 'osctld/container/impermanence'
require 'osctld/container/run_configuration'
require 'osctld/utils/container'
require 'osctld/utils/switch_user'
require 'osctld/commands/container/start'

RSpec.describe OsCtld::Commands::Container::Start do
  # Stop at the first distconfig call, before scheduling or spawning LXC. Inspect
  # the file using the real reader, independently of the in-memory selection.
  let(:prepared_root_error) { Class.new(StandardError) }

  def prepare_start(root, custom_boot: false)
    ct = build_run_config_container(root:, distribution: 'nixos')
    rc = OsCtld::Container::RunConfiguration.new(ct, load_conf: false)
    ct.define_singleton_method(:can_start?) { true }
    ct.define_singleton_method(:state) { :stopped }
    ct.define_singleton_method(:impermanence) { OsCtld::Container::Impermanence.new({}) }
    ct.define_singleton_method(:run_conf) { rc }
    ct.define_singleton_method(:init_run_conf) { rc.save }
    mounts = Struct.new(:prune_calls) do
      def prune
        self.prune_calls += 1
      end
    end.new(0)
    ct.define_singleton_method(:mounts) { mounts }
    command = described_class.new({ custom_boot: }, {})
    allow(command).to receive(:remove_accounting_cgroups)

    stub_const('OsCtld::DistConfig', Module.new do
      def self.run(*); end
    end)
    allow(OsCtld::DistConfig).to receive(:run).with(rc, :pre_start).and_raise(prepared_root_error)
    [ct, rc, command]
  end

  def prepare_temporary_dataset(root, ct, rc)
    dataset = FakeObjects::FakeDataset.new(
      name: "#{ct.dataset}.impermanence-123abc",
      mountpoint: File.join(root, 'temporary')
    )
    dataset.define_singleton_method(:create!) { |properties:| properties }
    FileUtils.mkdir_p(File.join(dataset.mountpoint, 'private'))
    allow(SecureRandom).to receive(:hex).with(3).and_return('123abc')
    allow(OsCtl::Lib::Zfs::Dataset).to receive(:new).and_call_original
    allow(OsCtl::Lib::Zfs::Dataset).to receive(:new)
      .with(dataset.name, base: dataset.name).and_return(dataset)

    stub_const('OsCtld::GarbageCollector', Class.new do
      def self.add_container_run_dataset(*); end
    end)
    allow(OsCtld::GarbageCollector).to receive(:add_container_run_dataset)
    builder_class = Class.new do
      def initialize(_run_conf, _opts = {}); end

      def shift_or_mount_dataset; end
      def setup_ct_dir; end
      def setup_rootfs; end
    end
    stub_const('OsCtld::Container::Builder', builder_class)
    builder = builder_class.new(rc)
    allow(builder_class).to receive(:new).with(rc, cmd: anything).and_return(builder)
    [dataset, builder]
  end

  it 'reloads the prepared root and cleanup ownership before any CPU assignment' do
    with_tmpdir do |root|
      ct, rc, command = prepare_start(root)
      dataset, = prepare_temporary_dataset(root, ct, rc)
      run_id = rc.run_id.dump

      expect { command.send(:start_now, ct) }.to raise_error(prepared_root_error)

      loaded = OsCtld::Container::RunConfiguration.load(ct)
      expect(loaded.dump).to include(
        'id' => run_id,
        'dataset' => dataset.name,
        'distribution' => 'nixos',
        'destroy_dataset_on_stop' => true,
        'cpu_package' => nil
      )
      expect(OsCtld::GarbageCollector).to have_received(:add_container_run_dataset).with(rc, dataset)
    end
  end

  it 'does not publish an unprepared temporary root when preparation fails' do
    with_tmpdir do |root|
      ct, rc, command = prepare_start(root)
      _dataset, builder = prepare_temporary_dataset(root, ct, rc)
      allow(builder).to receive(:setup_rootfs).and_raise('preparation failed')

      expect { command.send(:start_now, ct) }.to raise_error('preparation failed')

      loaded = OsCtld::Container::RunConfiguration.load(ct)
      expect(loaded.dataset.name).to eq(ct.dataset.name)
      expect(loaded.destroy_dataset_on_stop?).to be(false)
      expect(OsCtld::DistConfig).not_to have_received(:run)
    end
  end

  it 'keeps the selection that custom boot prepared before run initialization' do
    with_tmpdir do |root|
      ct, rc, command = prepare_start(root, custom_boot: true)
      dataset = FakeObjects::FakeDataset.new(
        name: 'tank/ct/ct1.boot-456def', mountpoint: File.join(root, 'custom')
      )
      rc.boot_from(
        dataset:, distribution: 'alpine', version: '3.24', arch: 'x86_64',
        vendor: 'custom', variant: 'minimal', destroy_dataset_on_stop: true
      )

      expect { command.send(:start_now, ct) }.to raise_error(prepared_root_error)

      loaded = OsCtld::Container::RunConfiguration.load(ct)
      expect(loaded.dump).to include(
        'dataset' => dataset.name, 'distribution' => 'alpine',
        'version' => '3.24', 'destroy_dataset_on_stop' => true
      )
    end
  end
end
