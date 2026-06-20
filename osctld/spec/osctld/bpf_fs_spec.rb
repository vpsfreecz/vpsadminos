# frozen_string_literal: true

require 'osctld/bpf_fs'

RSpec.describe OsCtld::BpfFs do
  it 'provides the logging interface required by syscmd' do
    expect(described_class.instance).to respond_to(:log)
    expect(described_class.instance.log_type).to eq('bpf-fs')
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
