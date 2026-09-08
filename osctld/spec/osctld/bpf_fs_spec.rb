# frozen_string_literal: true

require 'osctld/bpf_fs'

RSpec.describe OsCtld::BpfFs do
  it 'provides the logging interface required by syscmd' do
    expect(described_class.instance).to respond_to(:log)
    expect(described_class.instance.log_type).to eq('bpf-fs')
  end

  describe '.setup' do
    let(:fs) { described_class.instance }

    before do
      allow(FileUtils).to receive(:mkdir_p)
      allow(fs).to receive(:mount_type).and_return(nil)
      allow(fs).to receive(:syscmd)
    end

    it 'reuses the already mounted host pin filesystem' do
      allow(fs).to receive(:mount_type).with(described_class::FS).and_return('bpf')

      described_class.setup

      expect(fs).not_to have_received(:syscmd)
      expect(FileUtils).to have_received(:mkdir_p).with(described_class::PROG_DIR)
    end

    it 'adopts the legacy filesystem before opening the existing program cache' do
      allow(fs).to receive(:mount_type).with('/sys/fs/bpf').and_return('bpf')
      calls = []
      allow(fs).to receive(:syscmd) { |command| calls << command }
      allow(FileUtils).to receive(:mkdir_p) { |path| calls << [:mkdir, path] }

      described_class.setup

      expect(calls).to eq([
                            [:mkdir, described_class::FS],
                            'mount --bind /sys/fs/bpf /run/osctl/bpf',
                            'mount --make-rprivate /run/osctl/bpf',
                            [:mkdir, described_class::PROG_DIR],
                            [:mkdir, described_class::CT_FS]
                          ])
    end

    it 'refuses a different mounted filesystem without replacing it' do
      allow(fs).to receive(:mount_type).with(described_class::FS).and_return('tmpfs')

      expect { described_class.setup }.to raise_error(/not a BPF filesystem/)
      expect(fs).not_to have_received(:syscmd)
      expect(FileUtils).not_to have_received(:mkdir_p).with(described_class::PROG_DIR)
    end

    it 'does not substitute a fresh filesystem when legacy pins are unavailable' do
      expect { described_class.setup }.to raise_error(/legacy BPF filesystem/)
      expect(fs).not_to have_received(:syscmd)
      expect(FileUtils).not_to have_received(:mkdir_p).with(described_class::PROG_DIR)
    end

    it 'propagates a failed legacy mount without opening an empty program cache' do
      allow(fs).to receive(:mount_type).with('/sys/fs/bpf').and_return('bpf')
      allow(fs).to receive(:syscmd).with('mount --bind /sys/fs/bpf /run/osctl/bpf').and_raise(Errno::EPERM)

      expect { described_class.setup }.to raise_error(Errno::EPERM)
      expect(FileUtils).not_to have_received(:mkdir_p).with(described_class::PROG_DIR)
    end
  end

  it 'manages pinned program and link paths inside the configured filesystem root' do
    with_tmpdir do |dir|
      stub_const('OsCtld::BpfFs::PROG_DIR', File.join(dir, 'progs'))
      stub_const('OsCtld::BpfFs::POOL_DIR', File.join(dir, 'pools'))
      stub_const('OsCtld::BpfFs::CT_FS', File.join(dir, 'ct-bpf'))
      ct_path = File.join(dir, 'ct-bpf', 'tank', 'ct1')
      mount_opts = 'nosuid,nodev,noexec,uid=100000,gid=100000,mode=700'
      escaped_opts = Shellwords.escape(mount_opts)
      allow(described_class.instance).to receive(:syscmd)
      allow(described_class.instance).to receive(:mount_type).and_return(nil)
      allow(described_class.instance).to receive(:mount_type).with(described_class::FS).and_return('bpf')

      described_class.setup
      described_class.add_pool('tank')
      described_class.setup_ct('tank', 'ct1', root_uid: 100_000, root_gid: 100_000)

      File.write(described_class.prog_pin_path('prog1'), 'prog')
      File.write(described_class.link_pin_path('tank', 'link1'), 'link')

      expect(described_class.prog_pinned?('prog1')).to be(true)
      expect(described_class.link_pinned?('tank', 'link1')).to be(true)
      expect(described_class.ct_mount_path('tank', 'ct1')).to eq(ct_path)
      expect(described_class.list_progs).to eq(%w[prog1])
      expect(described_class.list_links('tank')).to eq(%w[link1])
      expect(described_class.instance).to have_received(:syscmd).with(
        "mount -t bpf -o #{escaped_opts} bpf #{ct_path}"
      )
      expect(described_class.instance).to have_received(:syscmd).with(
        "mount --make-rprivate #{ct_path}"
      )

      described_class.remove_ct('tank', 'ct1')

      expect(described_class.instance).to have_received(:syscmd).with(
        "umount -f #{ct_path}",
        valid_rcs: [32]
      )

      described_class.remove_pool('tank')

      expect(described_class.list_links('tank')).to eq([])
    end
  end

  it 'remounts an existing container bpffs with mapped root ownership' do
    with_tmpdir do |dir|
      stub_const('OsCtld::BpfFs::CT_FS', File.join(dir, 'ct-bpf'))
      ct_path = File.join(dir, 'ct-bpf', 'tank', 'ct1')
      mount_opts = 'nosuid,nodev,noexec,uid=200000,gid=300000,mode=700'
      escaped_opts = Shellwords.escape(mount_opts)
      allow(described_class.instance).to receive(:syscmd)
      allow(described_class.instance).to receive(:mount_type).and_return('bpf')

      described_class.setup_ct('tank', 'ct1', root_uid: 200_000, root_gid: 300_000)

      expect(described_class.instance).to have_received(:syscmd).with(
        "mount -o remount,#{escaped_opts} #{ct_path}"
      )
      expect(described_class.instance).to have_received(:syscmd).with(
        "mount --make-rprivate #{ct_path}"
      )
    end
  end

  it 'replaces a stale non-bpffs container mount before LXC can bind it' do
    with_tmpdir do |dir|
      stub_const('OsCtld::BpfFs::CT_FS', File.join(dir, 'ct-bpf'))
      ct_path = File.join(dir, 'ct-bpf', 'tank', 'ct1')
      mount_opts = 'nosuid,nodev,noexec,uid=400000,gid=500000,mode=700'
      escaped_opts = Shellwords.escape(mount_opts)
      allow(described_class.instance).to receive(:syscmd)
      allow(described_class.instance).to receive(:mount_type).and_return('tmpfs')

      described_class.setup_ct('tank', 'ct1', root_uid: 400_000, root_gid: 500_000)

      expect(described_class.instance).to have_received(:syscmd).with(
        "umount -f #{ct_path}",
        valid_rcs: [32]
      ).ordered
      expect(described_class.instance).to have_received(:syscmd).with(
        "mount -t bpf -o #{escaped_opts} bpf #{ct_path}"
      ).ordered
      expect(described_class.instance).to have_received(:syscmd).with(
        "mount --make-rprivate #{ct_path}"
      )
    end
  end
end
