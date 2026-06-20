# frozen_string_literal: true

module OsCtld
  module ContainerControl
    module Commands; end
  end
end

require 'osctld/container_control/commands/mount'

RSpec.describe OsCtld::ContainerControl::Commands::Mount do
  # These partial protocol doubles keep the unit test independent of the full
  # container object graph.
  # rubocop:disable RSpec/MultipleMemoizedHelpers, RSpec/VerifiedDoubles
  describe described_class::Frontend do
    let(:cgroup_path) { '/osctl/pool.tank/user.test/ct.ct1/user-owned' }
    let(:files) { [instance_double(IO), instance_double(File), instance_double(File)] }
    let(:identity) do
      instance_double(
        OsCtld::ProcessIdentity,
        pid: 123,
        files:,
        close: nil
      )
    end
    let(:lease) do
      double(
        'init lease',
        identity:,
        close: nil
      )
    end
    let(:run_conf) { double('run configuration', init_pid: 123) }
    let(:ct) do
      double(
        'container',
        init_pid: 123,
        refresh_init_pid: 123,
        run_conf:,
        running?: true,
        cgroup_path:,
        root_host_uid: 100_000,
        root_host_gid: 100_000
      )
    end
    let(:frontend) do
      described_class.new(OsCtld::ContainerControl::Commands::Mount, ct)
    end
    let(:opts) { { shared_dir: '/run/osctl/mounts', src: 'abc123', dst: '/mnt/data' } }
    let(:runner_result) { OsCtld::ContainerControl::Result.new(true) }

    before do
      allow(ct).to receive(:inclusively).and_yield
      allow(identity).to receive(:authenticate!).and_return(identity)
      allow(run_conf).to receive(:acquire_init_lease)
        .with(namespaces: [:mnt], root: true)
        .and_return(lease)
      allow(frontend).to receive(:fork_runner).and_return(runner_result)
    end

    it 'runs with one authenticated identity from the exact current run' do
      expect(frontend.execute(opts)).to be(true)

      expect(identity).to have_received(:authenticate!).with(cgroup_path:)
      expect(frontend).to have_received(:fork_runner).with(
        args: [opts.merge(
          init_identity: identity,
          cgroup_path:,
          root_host_uid: 100_000,
          root_host_gid: 100_000
        )],
        keep_fds: files,
        switch_to_system: false
      )
      expect(lease).to have_received(:close)
    end

    it 'releases shared state locks before the runner and holds only the run lease' do
      ct_locked = false
      lease_closed = false

      allow(ct).to receive(:inclusively) do |&block|
        ct_locked = true
        block.call
      ensure
        ct_locked = false
      end
      allow(lease).to receive(:close) do
        lease_closed = true
      end
      allow(frontend).to receive(:fork_runner) do
        expect(ct_locked).to be(false)
        expect(lease_closed).to be(false)
        runner_result
      end

      expect(frontend.execute(opts)).to be(true)
      expect(ct_locked).to be(false)
      expect(lease_closed).to be(true)
    end

    it 'rejects a stopped container without resolving or forking' do
      allow(ct).to receive(:running?).and_return(false)

      ret = frontend.execute(opts)

      expect(ret).to be_a(OsCtld::ContainerControl::Result)
      expect(ret).not_to be_ok
      expect(ret.message).to match(/not running/)
      expect(run_conf).not_to have_received(:acquire_init_lease)
      expect(frontend).not_to have_received(:fork_runner)
    end

    it 'rejects a missing run without refreshing or creating one' do
      allow(ct).to receive(:run_conf).and_return(nil)

      ret = frontend.execute(opts)

      expect(ret).not_to be_ok
      expect(ct).not_to have_received(:refresh_init_pid)
      expect(frontend).not_to have_received(:fork_runner)
    end

    it 'refreshes a missing PID only for the captured run' do
      allow(run_conf).to receive(:init_pid).and_return(nil, 123, 123)
      allow(ct).to receive(:refresh_init_pid)
        .with(expected_run_conf: run_conf)
        .and_return(123)

      expect(frontend.execute(opts)).to be(true)

      expect(ct).to have_received(:refresh_init_pid).with(expected_run_conf: run_conf)
    end

    it 'rejects an exited or reused PID before forking' do
      allow(run_conf).to receive(:acquire_init_lease)
        .with(namespaces: [:mnt], root: true)
        .and_raise(Errno::ESRCH, 'process exited')

      ret = frontend.execute(opts)

      expect(ret).not_to be_ok
      expect(ret.message).to match(/unable to resolve container init identity/)
      expect(frontend).not_to have_received(:fork_runner)
    end

    it 'rejects an init process outside the container cgroup' do
      allow(identity).to receive(:authenticate!)
        .with(cgroup_path:)
        .and_raise(Errno::EXDEV, 'foreign cgroup')

      ret = frontend.execute(opts)

      expect(ret).not_to be_ok
      expect(ret.message).to match(/foreign cgroup/)
      expect(frontend).not_to have_received(:fork_runner)
    end

    it 'rejects a run replacement after identity resolution' do
      replacement = double('replacement run configuration')
      allow(ct).to receive(:run_conf).and_return(run_conf, run_conf, replacement)

      ret = frontend.execute(opts)

      expect(ret).not_to be_ok
      expect(ret.message).to match(/run changed/)
      expect(frontend).not_to have_received(:fork_runner)
    end

    it 'rejects an identity substituted for the captured init PID' do
      substituted = instance_double(
        OsCtld::ProcessIdentity,
        pid: 999,
        files:,
        close: nil
      )
      substituted_lease = double(
        'substituted init lease',
        identity: substituted,
        close: nil
      )
      allow(substituted).to receive(:authenticate!).and_return(substituted)
      allow(run_conf).to receive(:acquire_init_lease)
        .with(namespaces: [:mnt], root: true)
        .and_return(substituted_lease)

      ret = frontend.execute(opts)

      expect(ret).not_to be_ok
      expect(ret.message).to match(/run changed/)
      expect(frontend).not_to have_received(:fork_runner)
      expect(substituted_lease).to have_received(:close)
    end
  end
  # rubocop:enable RSpec/MultipleMemoizedHelpers, RSpec/VerifiedDoubles

  # rubocop:disable RSpec/MultipleMemoizedHelpers
  describe described_class::Runner do
    let(:runner_class) do
      Class.new(described_class) do
        attr_accessor :relocate_log

        attr_reader :entered_mountns, :prepared_mountpoint

        def public_relocate_mount(src, dst, create: true)
          relocate_mount(src, dst, create:)
        end

        def public_prepare_mountpoint(dst, uid:, gid:)
          prepare_mountpoint(dst, uid:, gid:)
        end

        def public_create_mountpoint_as(dst, uid:, gid:)
          create_mountpoint_as(dst, uid:, gid:)
        end

        def prepare_mountpoint(dst, uid:, gid:)
          @prepared_mountpoint = dst
        end

        def enter_container_mountns(identity, cgroup_path)
          authenticate_current_init!(identity, cgroup_path)
          @entered_mountns = [identity, cgroup_path]
        end

        def relocate_mount(src, dst, create: true)
          if relocate_log
            File.write(relocate_log, "#{src}\n#{dst}\n#{create}\n")
          else
            super
          end
        end
      end
    end

    let(:runner) do
      runner_class.new(
        pool: 'tank',
        id: 'ct1',
        lxc_home: '/run/lxc',
        user_home: '/home/test',
        log_file: '/tank/log/ct/ct1.log'
      )
    end

    let(:sys) do
      instance_double(
        OsCtl::Lib::Sys,
        fchdir_io: 0,
        chroot: 0,
        make_private: 0,
        move_mount: 0,
        pidfd_alive?: true,
        setns_io: nil
      )
    end

    let(:pidfd) { instance_double(IO) }
    let(:root_dir) { instance_double(File) }
    let(:mnt_ns) { instance_double(File) }
    let(:cgroup_path) { '/osctl/pool.tank/user.test/ct.ct1/user-owned' }
    let(:identity) do
      instance_double(
        OsCtld::ProcessIdentity,
        pid: 123,
        pidfd:,
        root_dir:,
        namespace: mnt_ns
      )
    end
    let(:lxc_ct) { instance_double(LXC::Container, init_pid: 123, running?: true) }

    before do
      allow(OsCtl::Lib::Sys).to receive(:new).and_return(sys)
      allow(identity).to receive(:authenticate!).and_return(identity)
      allow(runner).to receive(:lxc_ct).and_return(lxc_ct)
    end

    it 'moves runtime mounts out of the shared helper and makes them private' do
      Dir.mktmpdir('osctld-mount-runner') do |dir|
        src = File.join(dir, 'helper', 'abc123')
        dst = File.join(dir, 'mnt', 'data')
        FileUtils.mkdir_p(src)

        runner.public_relocate_mount(src, dst)

        expect(sys).to have_received(:move_mount).with(src, dst).ordered
        expect(sys).to have_received(:make_private).with(dst).ordered
      end
    end

    it 'creates runtime mountpoints as mapped container root' do
      mountpoint_runner_class = Class.new(described_class) do
        def public_create_mountpoint_as(dst, uid:, gid:)
          create_mountpoint_as(dst, uid:, gid:)
        end
      end
      mountpoint_runner = mountpoint_runner_class.new(
        pool: 'tank',
        id: 'ct1',
        lxc_home: '/run/lxc',
        user_home: '/home/test',
        log_file: '/tank/log/ct/ct1.log'
      )

      allow(OsCtld::SwitchUser).to receive(:switch_to_system)
      allow(FileUtils).to receive(:mkdir_p)

      expect(
        mountpoint_runner.public_create_mountpoint_as(
          '/mnt/data',
          uid: 100_000,
          gid: 100_001
        )
      ).to be(true)

      expect(OsCtld::SwitchUser).to have_received(:switch_to_system).with(
        '',
        100_000,
        100_001,
        '/'
      )
      expect(FileUtils).to have_received(:mkdir_p).with('/mnt/data')
    end

    it 'fails when the mapped-root mountpoint creator fails' do
      mountpoint_runner_class = Class.new(described_class) do
        def public_prepare_mountpoint(dst, uid:, gid:)
          prepare_mountpoint(dst, uid:, gid:)
        end
      end
      mountpoint_runner = mountpoint_runner_class.new(
        pool: 'tank',
        id: 'ct1',
        lxc_home: '/run/lxc',
        user_home: '/home/test',
        log_file: '/tank/log/ct/ct1.log'
      )

      status = instance_double(Process::Status, success?: false, exitstatus: 42)
      allow(Process).to receive(:fork).and_return(1234)
      allow(Process).to receive(:wait2).with(1234).and_return([1234, status])

      expect do
        mountpoint_runner.public_prepare_mountpoint(
          '/mnt/data',
          uid: 100_000,
          gid: 100_001
        )
      end.to raise_error(RuntimeError, 'mkdir -p "/mnt/data" exited with 42')
    end

    it 'relocates runtime mounts from the container mount namespace' do
      Dir.mktmpdir('osctld-mount-runner') do |dir|
        src = File.join(dir, 'abc123')
        dst = File.join(dir, 'mnt', 'data')
        relocate_log = File.join(dir, 'relocate.log')
        FileUtils.mkdir_p(src)
        runner.relocate_log = relocate_log

        ret = runner.execute(
          shared_dir: dir,
          src: 'abc123',
          dst:,
          init_identity: identity,
          cgroup_path:,
          root_host_uid: 100_000,
          root_host_gid: 100_000
        )

        expect(ret[:status]).to be(true)
        expect(runner.prepared_mountpoint).to eq(dst)
        expect(runner.entered_mountns).to eq([identity, cgroup_path])
        expect(File.read(relocate_log).split("\n")).to eq([src, dst, 'false'])
        expect(identity).to have_received(:authenticate!).with(cgroup_path:).exactly(3).times
      end
    end

    it 'enters the container mount namespace before chrooting' do
      namespace_runner_class = Class.new(described_class) do
        def public_enter_container_mountns(identity, cgroup_path)
          enter_container_mountns(identity, cgroup_path)
        end
      end
      namespace_runner = namespace_runner_class.new(
        pool: 'tank',
        id: 'ct1',
        lxc_home: '/run/lxc',
        user_home: '/home/test',
        log_file: '/tank/log/ct/ct1.log'
      )
      allow(namespace_runner).to receive(:lxc_ct).and_return(lxc_ct)

      allow(Dir).to receive(:chdir).with('/')

      namespace_runner.public_enter_container_mountns(identity, cgroup_path)

      expect(identity).to have_received(:authenticate!).with(cgroup_path:).twice.ordered
      expect(sys).to have_received(:pidfd_alive?).with(pidfd).ordered
      expect(sys).to have_received(:setns_io).with(mnt_ns, OsCtl::Lib::Sys::CLONE_NEWNS).ordered
      expect(sys).to have_received(:fchdir_io).with(root_dir).ordered
      expect(sys).to have_received(:chroot).with('.').ordered
      expect(Dir).to have_received(:chdir).with('/').ordered
    end

    it 'does not enter a namespace or move a mount when identity authentication fails' do
      allow(identity).to receive(:authenticate!)
        .with(cgroup_path:)
        .and_raise(Errno::EXDEV, 'foreign cgroup')

      ret = runner.execute(
        shared_dir: '/run/osctl/mounts',
        src: 'abc123',
        dst: '/mnt/data',
        init_identity: identity,
        cgroup_path:,
        root_host_uid: 100_000,
        root_host_gid: 100_000
      )

      expect(ret[:status]).to be(false)
      expect(sys).not_to have_received(:setns_io)
      expect(sys).not_to have_received(:move_mount)
      expect(sys).not_to have_received(:make_private)
    end

    it 'revalidates descriptor identity before namespace entry' do
      namespace_runner_class = Class.new(described_class) do
        def prepare_mountpoint(_dst, uid:, gid:); end
      end
      namespace_runner = namespace_runner_class.new(
        pool: 'tank',
        id: 'ct1',
        lxc_home: '/run/lxc',
        user_home: '/home/test',
        log_file: '/tank/log/ct/ct1.log'
      )
      allow(namespace_runner).to receive(:lxc_ct).and_return(lxc_ct)
      auth_calls = 0
      allow(identity).to receive(:authenticate!).with(cgroup_path:) do
        auth_calls += 1
        raise Errno::ESTALE, 'substituted mount namespace' if auth_calls == 2

        identity
      end

      ret = namespace_runner.execute(
        shared_dir: '/run/osctl/mounts',
        src: 'abc123',
        dst: '/mnt/data',
        init_identity: identity,
        cgroup_path:,
        root_host_uid: 100_000,
        root_host_gid: 100_000
      )

      expect(ret[:status]).to be(false)
      expect(sys).not_to have_received(:setns_io)
      expect(sys).not_to have_received(:move_mount)
      expect(sys).not_to have_received(:make_private)
    end

    it 'revalidates identity after namespace entry before mount relocation' do
      namespace_runner_class = Class.new(described_class) do
        def prepare_mountpoint(_dst, uid:, gid:); end
      end
      namespace_runner = namespace_runner_class.new(
        pool: 'tank',
        id: 'ct1',
        lxc_home: '/run/lxc',
        user_home: '/home/test',
        log_file: '/tank/log/ct/ct1.log'
      )
      allow(namespace_runner).to receive(:lxc_ct).and_return(lxc_ct)
      auth_calls = 0
      allow(identity).to receive(:authenticate!).with(cgroup_path:) do
        auth_calls += 1
        raise Errno::ESRCH, 'init exited' if auth_calls == 3

        identity
      end
      allow(Dir).to receive(:chdir).with('/')

      Dir.mktmpdir('osctld-mount-runner-auth') do |dir|
        src = File.join(dir, 'abc123')
        FileUtils.mkdir_p(src)

        ret = namespace_runner.execute(
          shared_dir: dir,
          src: 'abc123',
          dst: '/mnt/data',
          init_identity: identity,
          cgroup_path:,
          root_host_uid: 100_000,
          root_host_gid: 100_000
        )

        expect(ret[:status]).to be(false)
      end

      expect(sys).to have_received(:setns_io).with(mnt_ns, OsCtl::Lib::Sys::CLONE_NEWNS)
      expect(sys).not_to have_received(:move_mount)
      expect(sys).not_to have_received(:make_private)
    end
  end
  # rubocop:enable RSpec/MultipleMemoizedHelpers
end
