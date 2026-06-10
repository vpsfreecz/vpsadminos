# frozen_string_literal: true

module OsCtld
  module Utils; end
end

require 'osctld/mount/entry'
require 'osctld/utils/switch_user'
require 'osctld/mount/shared_dir'

RSpec.describe OsCtld::Mount::SharedDir do
  let(:pool) { build_fake_pool(root: Dir.mktmpdir('osctld-shared-dir')) }
  let(:ct) { FakeObjects::FakeRuntimeContainer.new(pool:, id: 'ct1', map_mode: 'zfs', init_pid: 4321) }
  let(:shared_dir) { described_class.new(ct) }

  before do
    OsCtl::Lib::Logger.setup(:none)
    stub_const('OsCtld::ContainerControl', Module.new)
    stub_const('OsCtld::ContainerControl::Commands', Module.new)
    stub_const('OsCtld::ContainerControl::Commands::Mount', Class.new do
      def self.run!(*); end
    end)
    allow(OsCtld::ContainerControl::Commands::Mount).to receive(:run!)
    allow(shared_dir).to receive(:syscmd).and_return(OsCtl::Lib::SystemCommandResult.new(0, ''))
  end

  after do
    FileUtils.rm_rf(File.dirname(pool.mount_dir))
  end

  it 'creates the shared directory, mount bindings, and README' do
    shared_dir.create

    expect(shared_dir).to have_received(:syscmd).with("mount --bind \"#{shared_dir.path}\" \"#{shared_dir.path}\"")
    expect(shared_dir).to have_received(:syscmd).with("mount --make-rshared \"#{shared_dir.path}\"")
    expect(File.read(File.join(shared_dir.path, 'README.txt'))).to include('/dev/.osctl-mount-helper')
  end

  it 'does not recreate host mounts when the directory already exists' do
    FileUtils.mkdir_p(shared_dir.path)

    shared_dir.create

    expect(shared_dir).not_to have_received(:syscmd)
    expect(File).to exist(File.join(shared_dir.path, 'README.txt'))
  end

  it 'unmounts and removes the shared directory' do
    FileUtils.mkdir_p(shared_dir.path)
    File.write(File.join(shared_dir.path, 'README.txt'), 'readme')

    shared_dir.remove

    expect(shared_dir).to have_received(:syscmd).with("umount -R -f \"#{shared_dir.path}\"", valid_rcs: :all)
    expect(File).not_to exist(shared_dir.path)
  end

  it 'removes stale directories left in the shared directory' do
    FileUtils.mkdir_p(File.join(shared_dir.path, 'stale'))

    shared_dir.remove

    expect(File).not_to exist(shared_dir.path)
  end

  it 'removes the shared directory when umount reports that it is not mounted' do
    FileUtils.mkdir_p(File.join(shared_dir.path, 'stale'))
    result = OsCtl::Lib::SystemCommandResult.new(
      1,
      "umount: #{shared_dir.path}: not mounted\n"
    )

    allow(shared_dir).to receive(:syscmd).with(
      "umount -R -f \"#{shared_dir.path}\"",
      valid_rcs: :all
    ).and_return(result)

    shared_dir.remove

    expect(File).not_to exist(shared_dir.path)
  end

  it 'propagates mounts through the shared directory' do
    FileUtils.mkdir_p(shared_dir.path)
    src = Dir.mktmpdir('mnt-src')
    mnt = OsCtld::Mount::Entry.new(src, '/data', 'bind', 'bind', true, map_ids: false)
    host_path = shared_dir.host_path_for('/data')

    shared_dir.propagate(mnt)

    expect(shared_dir).to have_received(:syscmd).with("mount --bind  \"#{src}\" \"#{host_path}\"")
    expect(OsCtld::ContainerControl::Commands::Mount).to have_received(:run!).with(
      ct,
      shared_dir: '/dev/.osctl-mount-helper',
      src: File.basename(host_path),
      dst: '/data'
    )
    expect(shared_dir).to have_received(:syscmd).with("umount \"#{host_path}\"")
    expect(File).not_to exist(host_path)
  ensure
    FileUtils.rm_rf(src)
  end

  it 'uses idmapped bind mounts for native mapping mode' do
    FileUtils.mkdir_p(shared_dir.path)
    src = Dir.mktmpdir('mnt-src')
    native_ct = FakeObjects::FakeRuntimeContainer.new(pool:, id: 'ct1', map_mode: 'native', init_pid: 555)
    native_shared_dir = described_class.new(native_ct)
    allow(native_shared_dir).to receive(:syscmd).and_return(OsCtl::Lib::SystemCommandResult.new(0, ''))
    allow(OsCtld::ContainerControl::Commands::Mount).to receive(:run!)
    mnt = OsCtld::Mount::Entry.new(src, '/data', 'bind', 'bind', true, map_ids: true)

    FileUtils.mkdir_p(native_shared_dir.path)
    native_shared_dir.propagate(mnt)

    expect(native_shared_dir).to have_received(:syscmd).with(
      include('X-mount.idmap=/proc/555/ns/user')
    )
  ensure
    FileUtils.rm_rf(src)
  end

  it 'maps and cleans up pushed directories' do
    FileUtils.mkdir_p(shared_dir.path)
    dir = Dir.mktmpdir('push-src')
    host_path = shared_dir.host_path_for(dir)

    expect(shared_dir.map_and_push(dir, 123)).to eq(host_path)
    expect(shared_dir).to have_received(:syscmd).with(
      "mount --bind -o X-mount.idmap=/proc/123/ns/user #{dir} #{host_path}"
    )

    shared_dir.cleanup_pushed(dir)

    expect(shared_dir).to have_received(:syscmd).with("umount \"#{host_path}\"", valid_rcs: [32])
    expect(File).not_to exist(host_path)
  ensure
    FileUtils.rm_rf(dir)
  end

  it 'builds deterministic host paths and rebinds duplicated containers' do
    expect(shared_dir.host_path_for('/data')).to eq(
      File.join(shared_dir.path, Digest::SHA2.hexdigest('/data'))
    )

    other_ct = FakeObjects::FakeRuntimeContainer.new(pool:, id: 'ct2')
    copy = shared_dir.dup(other_ct)

    expect(copy.path).to eq(File.join(pool.mount_dir, 'ct2'))
  end
end
