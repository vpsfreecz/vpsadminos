# frozen_string_literal: true

require 'osctld/exceptions'
require 'osctld/promise'
require 'osctld/container/run_id'
require 'osctld/container/run_configuration'

RSpec.describe OsCtld::Container::RunConfiguration do
  def build_run_configuration(root:, **opts)
    ct = build_run_config_container(root:, **opts)
    [ct, described_class.new(ct, load_conf: false)]
  end

  it 'initializes from container defaults when no runtime config exists' do
    with_tmpdir do |dir|
      ct, rc = build_run_configuration(root: dir)

      expect(rc.dataset).to eq(ct.dataset)
      expect(rc.distribution).to eq(ct.distribution)
      expect(rc.version).to eq(ct.version)
      expect(rc.arch).to eq(ct.arch)
      expect(rc.vendor).to eq(ct.vendor)
      expect(rc.variant).to eq(ct.variant)
      expect(rc.destroy_dataset_on_stop?).to be(false)
      expect(rc.run_id.to_s).to include('tank:ct1:')
    end
  end

  it 'returns nil from .load when the runtime config file is missing' do
    with_tmpdir do |dir|
      ct = build_run_config_container(root: dir)

      expect(described_class.load(ct)).to be_nil
    end
  end

  it 'updates boot parameters through boot_from' do
    with_tmpdir do |dir|
      _ct, rc = build_run_configuration(root: dir)
      boot_dataset = FakeObjects::FakeDataset.new(
        name: 'tank/imports/ct1',
        mountpoint: File.join(dir, 'datasets', 'boot')
      )
      FileUtils.mkdir_p(boot_dataset.mountpoint)

      rc.boot_from(
        dataset: boot_dataset,
        distribution: 'nixos',
        version: '24.11',
        arch: 'x86_64',
        vendor: 'custom',
        variant: 'minimal',
        destroy_dataset_on_stop: true
      )

      expect(rc.dataset).to eq(boot_dataset)
      expect(rc.distribution).to eq('nixos')
      expect(rc.version).to eq('24.11')
      expect(rc.arch).to eq('x86_64')
      expect(rc.vendor).to eq('custom')
      expect(rc.variant).to eq('minimal')
      expect(rc.destroy_dataset_on_stop?).to be(true)
    end
  end

  it 'persists distribution updates through set_distribution' do
    with_tmpdir do |dir|
      ct, rc = build_run_configuration(root: dir)

      rc.set_distribution(
        distribution: 'nixos',
        version: '24.11',
        arch: 'aarch64',
        vendor: 'custom',
        variant: 'minimal'
      )

      loaded = described_class.load(ct)

      expect(loaded.distribution).to eq('nixos')
      expect(loaded.version).to eq('24.11')
      expect(loaded.arch).to eq('aarch64')
      expect(loaded.vendor).to eq('custom')
      expect(loaded.variant).to eq('minimal')
    end
  end

  it 'round-trips saved runtime configuration' do
    with_tmpdir do |dir|
      ct, rc = build_run_configuration(root: dir)
      boot_dataset = FakeObjects::FakeDataset.new(
        name: 'tank/imports/ct1',
        mountpoint: File.join(dir, 'datasets', 'boot')
      )
      FileUtils.mkdir_p(boot_dataset.mountpoint)

      rc.boot_from(
        dataset: boot_dataset,
        distribution: 'nixos',
        version: '24.11',
        arch: 'x86_64',
        vendor: 'custom',
        variant: 'minimal',
        destroy_dataset_on_stop: true
      )
      rc.cpu_package = 2
      rc.save

      loaded = described_class.load(ct)

      expect(loaded.dump).to include(
        'dataset' => 'tank/imports/ct1',
        'distribution' => 'nixos',
        'version' => '24.11',
        'arch' => 'x86_64',
        'vendor' => 'custom',
        'variant' => 'minimal',
        'cpu_package' => 2,
        'destroy_dataset_on_stop' => true
      )
      expect(loaded.dataset.name).to eq('tank/imports/ct1')
      expect(loaded.destroy_dataset_on_stop?).to be(true)
    end
  end

  it 'mounts the boot dataset when it differs from the base dataset' do
    with_tmpdir do |dir|
      ct, rc = build_run_configuration(root: dir)
      boot_dataset = FakeObjects::FakeDataset.new(
        name: 'tank/imports/ct1',
        mountpoint: File.join(dir, 'datasets', 'boot')
      )
      FileUtils.mkdir_p(boot_dataset.mountpoint)

      rc.boot_from(
        dataset: boot_dataset,
        distribution: ct.distribution,
        version: ct.version,
        arch: ct.arch,
        vendor: ct.vendor,
        variant: ct.variant
      )

      allow(ct).to receive(:mount).and_call_original

      rc.mount

      expect(ct).to have_received(:mount).with(force: false)
      expect(boot_dataset.mount_calls).to eq([true])
      expect(rc.mounted?(force: false)).to be(true)
    end
  end

  it 'forwards force mounts to the container dataset mount' do
    with_tmpdir do |dir|
      ct, rc = build_run_configuration(root: dir)

      allow(ct).to receive(:mount).and_call_original

      rc.mount(force: true)

      expect(ct).to have_received(:mount).with(force: true)
    end
  end

  it 'builds the runtime rootfs from the init pid' do
    with_tmpdir do |dir|
      _ct, rc = build_run_configuration(root: dir)

      rc.init_pid = 4321

      expect(rc.runtime_rootfs).to eq('/proc/4321/root')
    end
  end

  it 'tracks abort and reboot state' do
    with_tmpdir do |dir|
      _ct, rc = build_run_configuration(root: dir)

      expect(rc.aborted?).to be(false)
      expect(rc.reboot?).to be(false)

      rc.aborted = true
      rc.request_reboot

      expect(rc.aborted?).to be(true)
      expect(rc.reboot?).to be(true)
    end
  end

  it 'fulfils exit promises' do
    with_tmpdir do |dir|
      _ct, rc = build_run_configuration(root: dir)
      promise = rc.get_exit_promise

      rc.fulfil_exit

      expect(promise.wait(timeout: 0.1)).to be(true)
    end
  end

  it 'reports whether distribution network configuration should run' do
    with_tmpdir do |dir|
      _ct, rc = build_run_configuration(root: dir)

      expect(rc.dist_configure_network?).to be(true)

      rc.dist_network_configured = true

      expect(rc.dist_configure_network?).to be(false)
    end
  end

  it 'returns false from dist_configure_network? when the container cannot configure networking' do
    with_tmpdir do |dir|
      _ct, rc = build_run_configuration(root: dir, can_dist_configure_network: false)

      expect(rc.dist_configure_network?).to be(false)
    end
  end

  it 'ignores missing runtime config files on destroy' do
    with_tmpdir do |dir|
      _ct, rc = build_run_configuration(root: dir)

      expect { rc.destroy }.not_to raise_error
    end
  end
end
