# frozen_string_literal: true

require 'osctld/container/start_menu'

StartMenuSpecSharedDir = Struct.new(:path, :mountpoint, keyword_init: true)
StartMenuSpecMountManager = Struct.new(:shared_dir, keyword_init: true)
StartMenuSpecContainer = Struct.new(:mounts, :log_type, keyword_init: true)

RSpec.describe OsCtld::Container::StartMenu do
  let(:shared_dir) do
    instance_double(
      StartMenuSpecSharedDir,
      path: File.join(dir, 'shared'),
      mountpoint: 'shared'
    )
  end
  let(:mounts) { instance_double(StartMenuSpecMountManager, shared_dir:) }
  let(:ct) { instance_double(StartMenuSpecContainer, mounts:, log_type: 'ct=tank:ct1') }
  let(:dir) { Dir.mktmpdir('start-menu-spec') }

  after do
    FileUtils.remove_entry(dir)
  end

  it 'defaults timeout to five seconds when loaded without a value' do
    menu = described_class.load(ct, {})

    expect(menu.timeout).to eq(5)
  end

  it 'builds host and container paths from the shared directory' do
    menu = described_class.new(ct, 15)

    expect(menu.host_path).to eq(File.join(dir, 'shared', 'ctstartmenu'))
    expect(menu.ct_path).to eq('/shared/ctstartmenu')
  end

  it 'prefixes the init command with the helper executable and timeout' do
    menu = described_class.new(ct, 15)

    expect(menu.init_cmd(['/sbin/init', '--unit=test'])).to eq(
      ['/shared/ctstartmenu', '-timeout', '15', '/sbin/init', '--unit=test']
    )
  end

  it 'dumps the timeout' do
    menu = described_class.new(ct, 12)

    expect(menu.dump).to eq('timeout' => 12)
  end

  it 'rebinds the container on dup' do
    replacement = instance_double(StartMenuSpecContainer, mounts:, log_type: 'ct=tank:ct9')
    menu = described_class.new(ct, 12)

    copy = menu.dup(replacement)

    expect(copy.ct).to eq(replacement)
    expect(copy.timeout).to eq(12)
  end

  it 'deploys and unlinks the helper file' do
    FileUtils.mkdir_p(shared_dir.path)

    source = File.join(dir, 'ctstartmenu.bin')
    File.write(source, 'start-menu')

    daemon = Object.new
    daemon.define_singleton_method(:config) do
      Object.new.tap do |cfg|
        cfg.define_singleton_method(:ctstartmenu) { source }
      end
    end
    stub_const('OsCtld::Daemon', Object.new.tap do |const|
      const.define_singleton_method(:get) { daemon }
    end)

    menu = described_class.new(ct, 12)
    menu.deploy

    expect(File.read(menu.host_path)).to eq('start-menu')

    menu.unlink
    expect(File.exist?(menu.host_path)).to be(false)

    expect { menu.unlink }.not_to raise_error
  end
end
