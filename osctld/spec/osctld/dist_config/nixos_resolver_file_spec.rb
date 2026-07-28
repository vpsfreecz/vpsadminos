# frozen_string_literal: true

require 'osctld/dist_config'
require 'osctld/dist_config/nixos_resolver_file'

RSpec.describe OsCtld::DistConfig::NixOSResolverFile do
  let(:payload) { "nameserver 192.0.2.53\noptions edns0\n" }

  it 'atomically installs a mapped-root-owned runtime handoff with bounded modes' do
    with_tmpdir do |root|
      run_dir = File.join(root, 'run')
      Dir.mkdir(run_dir)
      writer = described_class.new(run_dir:, random_hex: -> { 'a1' })

      expect(writer.write(payload)).to be(true)

      managed_dir = File.join(run_dir, 'vpsadminos')
      target = File.join(managed_dir, 'resolv.conf')
      expect(File.binread(target)).to eq(payload)
      expect(File.stat(managed_dir).mode & 0o777).to eq(0o755)
      expect(File.stat(target).mode & 0o777).to eq(0o644)
      expect(File.stat(managed_dir).uid).to eq(Process.euid)
      expect(File.stat(target).uid).to eq(Process.euid)
      expect(Dir.children(managed_dir)).to eq(['resolv.conf'])
    end
  end

  it 'replaces an existing regular target without leaving the temporary file' do
    with_tmpdir do |root|
      run_dir = File.join(root, 'run')
      managed_dir = File.join(run_dir, 'vpsadminos')
      FileUtils.mkdir_p(managed_dir)
      File.write(File.join(managed_dir, 'resolv.conf'), 'old')

      described_class.new(run_dir:, random_hex: -> { 'b2' }).write(payload)

      expect(File.binread(File.join(managed_dir, 'resolv.conf'))).to eq(payload)
      expect(Dir.children(managed_dir)).to eq(['resolv.conf'])
    end
  end

  it 'refuses a symlinked managed directory' do
    with_tmpdir do |root|
      run_dir = File.join(root, 'run')
      outside = File.join(root, 'outside')
      Dir.mkdir(run_dir)
      Dir.mkdir(outside)
      File.symlink(outside, File.join(run_dir, 'vpsadminos'))

      expect do
        described_class.new(run_dir:).write(payload)
      end.to raise_error(Errno::ENOTDIR)

      expect(Dir.children(outside)).to be_empty
    end
  end

  it 'refuses a symlinked target' do
    with_tmpdir do |root|
      run_dir = File.join(root, 'run')
      managed_dir = File.join(run_dir, 'vpsadminos')
      outside = File.join(root, 'outside')
      FileUtils.mkdir_p(managed_dir)
      File.write(outside, 'untouched')
      File.symlink(outside, File.join(managed_dir, 'resolv.conf'))

      expect do
        described_class.new(run_dir:).write(payload)
      end.to raise_error(Errno::EINVAL)

      expect(File.binread(outside)).to eq('untouched')
    end
  end

  it 'refuses a pre-created temporary path without deleting it' do
    with_tmpdir do |root|
      run_dir = File.join(root, 'run')
      managed_dir = File.join(run_dir, 'vpsadminos')
      FileUtils.mkdir_p(managed_dir)
      attack = File.join(managed_dir, '.resolv.conf.deadbeef')
      File.write(attack, 'attacker')

      expect do
        described_class.new(
          run_dir:,
          random_hex: -> { 'deadbeef' }
        ).write(payload)
      end.to raise_error(Errno::EEXIST)

      expect(File.binread(attack)).to eq('attacker')
    end
  end

  it 'fails closed when the managed directory is replaced during installation' do
    with_tmpdir do |root|
      run_dir = File.join(root, 'run')
      managed_dir = File.join(run_dir, 'vpsadminos')
      detached_dir = File.join(run_dir, 'detached')
      Dir.mkdir(run_dir)
      sys = OsCtl::Lib::Sys.new

      allow(sys).to receive(:renameat).and_wrap_original do |method, *args|
        File.rename(managed_dir, detached_dir)
        Dir.mkdir(managed_dir)
        method.call(*args)
      end

      expect do
        described_class.new(
          run_dir:,
          random_hex: -> { 'c3' },
          sys:
        ).write(payload)
      end.to raise_error(Errno::ESTALE)

      expect(Dir.children(managed_dir)).to be_empty
      expect(File.binread(File.join(detached_dir, 'resolv.conf'))).to eq(payload)
    end
  end

  it 'fails closed when the temporary entry is replaced before rename' do
    with_tmpdir do |root|
      run_dir = File.join(root, 'run')
      managed_dir = File.join(run_dir, 'vpsadminos')
      temporary = File.join(managed_dir, '.resolv.conf.d4')
      Dir.mkdir(run_dir)
      sys = OsCtl::Lib::Sys.new

      allow(sys).to receive(:renameat).and_wrap_original do |method, *args|
        File.unlink(temporary)
        File.write(temporary, 'attacker')
        method.call(*args)
      end

      expect do
        described_class.new(
          run_dir:,
          random_hex: -> { 'd4' },
          sys:
        ).write(payload)
      end.to raise_error(Errno::ESTALE)

      expect(File.binread(File.join(managed_dir, 'resolv.conf'))).to eq('attacker')
    end
  end

  it 'removes its own temporary file when installation fails before rename' do
    with_tmpdir do |root|
      run_dir = File.join(root, 'run')
      managed_dir = File.join(run_dir, 'vpsadminos')
      Dir.mkdir(run_dir)
      sys = OsCtl::Lib::Sys.new
      chmod_calls = 0

      allow(sys).to receive(:fchmod).and_wrap_original do |method, *args|
        chmod_calls += 1
        raise Errno::EIO if chmod_calls == 2

        method.call(*args)
      end

      expect do
        described_class.new(
          run_dir:,
          random_hex: -> { 'e5' },
          sys:
        ).write(payload)
      end.to raise_error(Errno::EIO)

      expect(Dir.children(managed_dir)).to be_empty
    end
  end
end
