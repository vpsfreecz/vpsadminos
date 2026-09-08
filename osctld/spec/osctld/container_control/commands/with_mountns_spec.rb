# frozen_string_literal: true

# rubocop:disable RSpec/MultipleMemoizedHelpers, RSpec/SubjectStub
# rubocop:disable RSpec/VerifiedDoubleReference

require 'osctld/container_control/commands/with_mountns'

RSpec.describe OsCtld::ContainerControl::Commands::WithMountns do
  describe described_class::Frontend do
    subject(:frontend) { described_class.new(OsCtld::ContainerControl::Commands::WithMountns, ct) }

    let(:ct) { instance_double('Container', mount: nil, get_run_conf: run_conf) }
    let(:run_conf) { instance_double('RunConfig') }
    let(:mnt_ns) { instance_double(IO) }
    let(:root_dir) { instance_double(File) }
    let(:result) { instance_double(OsCtld::ContainerControl::Result, ok?: true, data: true) }
    let(:block) { proc { true } }

    it 'keeps stable mount and root handles in the forked runner' do
      allow(frontend).to receive(:fork_runner).and_return(result)

      expect(
        frontend.execute(
          mnt_ns:,
          root_dir:,
          switch_to_system: false,
          block:
        )
      ).to be(true)
      expect(frontend).to have_received(:fork_runner).with(
        args: [{
          ctrc: run_conf,
          ns_pid: nil,
          mnt_ns:,
          chroot: nil,
          root_dir:,
          switch_to_system: false,
          block:
        }],
        keep_fds: [mnt_ns, root_dir],
        switch_to_system: false
      )
    end
  end

  describe described_class::Runner do
    subject(:runner) do
      described_class.new(
        pool: 'tank',
        id: 'ct1',
        lxc_home: '/var/lib/lxc',
        user_home: '/run/osctl/users/alice',
        log_file: '/var/log/ct1.log',
        stdout: $stdout,
        stderr: $stderr
      )
    end

    let(:sys) { instance_double(OsCtl::Lib::Sys) }
    let(:mnt_ns) { instance_double(IO) }
    let(:root_dir) { instance_double(File) }

    it 'enters and chroots through an already-open descriptor without a path' do
      allow(OsCtl::Lib::Sys).to receive(:new).and_return(sys)
      allow(sys).to receive(:setns_io)
      allow(sys).to receive(:fchdir_io)
      allow(sys).to receive(:chroot)
      allow(Dir).to receive(:chdir)
      allow(OsCtl::Lib::Logger).to receive(:setup)

      expect(
        runner.execute(
          mnt_ns:,
          root_dir:,
          switch_to_system: false,
          block: proc { 'done' }
        )
      ).to eq(status: true, output: 'done')
      expect(sys).to have_received(:setns_io).with(
        mnt_ns,
        OsCtl::Lib::Sys::CLONE_NEWNS
      )
      expect(sys).to have_received(:fchdir_io).with(root_dir)
      expect(sys).to have_received(:chroot).with('.')
      expect(Dir).to have_received(:chdir).with('/')
      expect(OsCtl::Lib::Logger).to have_received(:setup).with(:stdout)
    end

    it 'reopens the authenticated root after entering the mount namespace' do
      root_stat = instance_double(File::Stat, dev: 1, ino: 10)
      namespace_root = instance_double(File, close: nil)
      reopened_root_dir = instance_double(IO, stat: root_stat, close: nil)
      authenticated_root_dir = instance_double(File, stat: root_stat)

      allow(OsCtl::Lib::Sys).to receive(:new).and_return(sys)
      allow(sys).to receive(:setns_io)
      allow(sys).to receive(:open_beneath).and_return(reopened_root_dir)
      allow(sys).to receive(:fchdir_io)
      allow(sys).to receive(:chroot)
      allow(File).to receive(:open)
        .with('/', File::RDONLY | File::NOFOLLOW)
        .and_return(namespace_root)
      allow(Dir).to receive(:chdir)
      allow(OsCtl::Lib::Logger).to receive(:setup)

      expect(
        runner.execute(
          mnt_ns:,
          chroot: '/run/osctl/pools/tank/rootfs',
          root_dir: authenticated_root_dir,
          switch_to_system: false,
          block: proc { 'done' }
        )
      ).to eq(status: true, output: 'done')
      expect(sys).to have_received(:setns_io).with(
        mnt_ns,
        OsCtl::Lib::Sys::CLONE_NEWNS
      )
      expect(sys).to have_received(:open_beneath).with(
        namespace_root,
        'run/osctl/pools/tank/rootfs'
      )
      expect(sys).to have_received(:fchdir_io).with(reopened_root_dir)
      expect(sys).to have_received(:chroot).with('.')
      expect(namespace_root).to have_received(:close)
      expect(reopened_root_dir).to have_received(:close)
    end

    it 'rejects a target-namespace path which is not the authenticated root' do
      authenticated_stat = instance_double(File::Stat, dev: 1, ino: 10)
      substituted_stat = instance_double(File::Stat, dev: 2, ino: 20)
      namespace_root = instance_double(File, close: nil)
      reopened_root_dir = instance_double(IO, stat: substituted_stat, close: nil)
      authenticated_root_dir = instance_double(File, stat: authenticated_stat)

      allow(OsCtl::Lib::Sys).to receive(:new).and_return(sys)
      allow(sys).to receive(:setns_io)
      allow(sys).to receive(:open_beneath).and_return(reopened_root_dir)
      allow(sys).to receive(:fchdir_io)
      allow(File).to receive(:open)
        .with('/', File::RDONLY | File::NOFOLLOW)
        .and_return(namespace_root)

      expect do
        runner.execute(
          mnt_ns:,
          chroot: '/run/osctl/pools/tank/rootfs',
          root_dir: authenticated_root_dir,
          switch_to_system: false,
          block: proc { 'done' }
        )
      end.to raise_error(Errno::EXDEV)
      expect(sys).not_to have_received(:fchdir_io)
      expect(namespace_root).to have_received(:close)
      expect(reopened_root_dir).to have_received(:close)
    end
  end
end

# rubocop:enable RSpec/MultipleMemoizedHelpers, RSpec/SubjectStub
# rubocop:enable RSpec/VerifiedDoubleReference
