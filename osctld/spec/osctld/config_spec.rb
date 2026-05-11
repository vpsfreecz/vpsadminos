# frozen_string_literal: true

require 'libosctl/cpu_mask'
require 'osctld/config'

RSpec.describe OsCtld::Config do
  def build_config(data)
    with_tmpdir do |dir|
      path = File.join(dir, 'config.json')
      File.write(path, JSON.dump(data))
      yield described_class.new(path)
    end
  end

  it 'uses top-level defaults' do
    build_config({}) do |config|
      expect(config.debug?).to be(false)
      expect(config.apparmor_paths).to eq([])
      expect(config.enable_time_namespace?).to be(true)
      expect(config.enable_lock_registry?).to be(false)
      expect(config.writeout_dirtied_pages?).to be(true)
      expect(config.ct_wrapper).to eq('osctld-ct-wrapper')
    end
  end

  it 'builds cpu scheduler defaults and parses packages' do
    build_config(
      'cpu_scheduler' => {
        'enable' => true,
        'packages' => {
          '0' => { 'cpu_mask' => '0-3' },
          '1' => { 'enable' => false, 'cpu_mask' => '4,5' }
        }
      }
    ) do |config|
      scheduler = config.cpu_scheduler
      package0 = scheduler.packages.fetch(0)
      package1 = scheduler.packages.fetch(1)

      expect(scheduler.enable?).to be(true)
      expect(scheduler.min_package_container_count_percent).to eq(90)
      expect(scheduler.sequential_start_priority_threshold).to eq(1000)
      expect(package0.id).to eq(0)
      expect(package0.enable?).to be(true)
      expect(package0.cpu_mask.to_s).to eq('0-3')
      expect(package1.id).to eq(1)
      expect(package1.enable?).to be(false)
      expect(package1.cpu_mask.to_a).to eq([4, 5])
    end
  end

  it 'expands send receive mbuffer options' do
    build_config({}) do |config|
      send_mbuffer = config.send_receive.send_mbuffer
      receive_mbuffer = config.send_receive.receive_mbuffer

      expect(send_mbuffer.command).to eq('mbuffer')
      expect(send_mbuffer.start_writing_at).to eq(5)
      expect(send_mbuffer.as_cli_options).to eq(['-s', '128k', '-m', '256M', '-P', '5'])
      expect(send_mbuffer.as_hash_options).to eq(
        command: 'mbuffer',
        block_size: '128k',
        buffer_size: '256M',
        start_writing_at: 5
      )
      expect(receive_mbuffer.start_writing_at).to eq(80)
    end
  end

  it 'uses trash bin defaults' do
    build_config({}) do |config|
      expect(config.trash_bin.prune_interval).to eq(6 * 60 * 60)
    end
  end

  it 'uses garbage collector defaults' do
    build_config({}) do |config|
      expect(config.garbage_collector.prune_interval).to eq(6 * 60 * 60)
    end
  end

  it 'loads garbage collector settings from garbage_collector' do
    build_config(
      'garbage_collector' => {
        'prune_interval' => 123
      }
    ) do |config|
      expect(config.garbage_collector.prune_interval).to eq(123)
    end
  end

  it 'overrides defaults from explicit json values' do
    build_config(
      'debug' => true,
      'apparmor_paths' => %w[/a /b],
      'enable_time_namespace' => false,
      'lock_registry' => true,
      'ct_wrapper' => '/run/current-system/sw/bin/osctld-ct-wrapper',
      'writeout_dirtied_pages' => false,
      'send_receive' => {
        'send_mbuffer' => {
          'command' => 'custom-mbuffer',
          'block_size' => '64k',
          'buffer_size' => '128M',
          'start_writing_at' => 10
        }
      },
      'trash_bin' => {
        'prune_interval' => 60
      },
      'garbage_collector' => {
        'prune_interval' => 120
      }
    ) do |config|
      expect(config.debug?).to be(true)
      expect(config.apparmor_paths).to eq(%w[/a /b])
      expect(config.enable_time_namespace?).to be(false)
      expect(config.enable_lock_registry?).to be(true)
      expect(config.ct_wrapper).to eq('/run/current-system/sw/bin/osctld-ct-wrapper')
      expect(config.writeout_dirtied_pages?).to be(false)
      expect(config.send_receive.send_mbuffer.command).to eq('custom-mbuffer')
      expect(config.send_receive.send_mbuffer.as_cli_options).to eq(['-s', '64k', '-m', '128M', '-P', '10'])
      expect(config.trash_bin.prune_interval).to eq(60)
      expect(config.garbage_collector.prune_interval).to eq(120)
    end
  end
end
