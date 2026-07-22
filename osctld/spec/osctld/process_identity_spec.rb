# frozen_string_literal: true

require 'fileutils'
require 'osctld/process_identity'

RSpec.describe OsCtld::ProcessIdentity do
  let(:sys) { instance_double(OsCtl::Lib::Sys) }
  let(:pidfd) do
    instance_double(
      IO,
      stat: instance_double(File::Stat, dev: 7, ino: 70),
      closed?: false,
      close: nil
    )
  end
  let(:opened_root_dir) do
    instance_double(
      IO,
      stat: instance_double(File::Stat, directory?: true, dev: 8, ino: 80),
      closed?: false,
      close: nil
    )
  end
  let(:proc_dir) do
    instance_double(
      File,
      fileno: 11,
      stat: instance_double(File::Stat, directory?: true, dev: 9, ino: 90),
      closed?: false,
      close: nil
    )
  end
  let(:retained_files) do
    {
      root: instance_double(File, closed?: false, close: nil),
      net_ns: instance_double(File, closed?: false, close: nil),
      pid_ns: instance_double(File, closed?: false, close: nil)
    }
  end

  def root_dir
    retained_files.fetch(:root)
  end

  def net_ns
    retained_files.fetch(:net_ns)
  end

  def pid_ns
    retained_files.fetch(:pid_ns)
  end

  before do
    allow(OsCtl::Lib::Sys).to receive(:new).and_return(sys)
    allow(sys).to receive(:pidfd_open).with(123).and_return(pidfd)
    allow(sys).to receive(:pidfd_alive?).with(pidfd).and_return(true)
  end

  # Ordered expectations prove that one retained proc directory is the source
  # of every identity descriptor.
  # rubocop:disable RSpec/MessageSpies
  it 'retains root and namespaces through one live proc directory' do
    expect(File).to receive(:open).with('/proc/123').ordered.and_return(proc_dir)
    expect(sys).to receive(:openat_io).with(proc_dir, 'root').ordered.and_return(root_dir)
    expect(sys).to receive(:openat_io).with(proc_dir, 'ns/net').ordered.and_return(net_ns)
    expect(sys).to receive(:openat_io).with(proc_dir, 'ns/pid').ordered.and_return(pid_ns)

    identity = described_class.new(123, namespaces: %i[net pid], root: true)

    expect(identity.pid).to eq(123)
    expect(identity.pidfd).to be(pidfd)
    expect(identity.root_dir).to be(root_dir)
    expect(identity.namespace(:net)).to be(net_ns)
    expect(identity.namespace(:pid)).to be(pid_ns)
    expect(identity.files).to eq([pidfd, proc_dir, root_dir, net_ns, pid_ns])
    expect(sys).to have_received(:pidfd_alive?).with(pidfd).twice

    identity.close

    expect(pidfd).to have_received(:close)
    expect(proc_dir).to have_received(:close)
    expect(root_dir).to have_received(:close)
    expect(net_ns).to have_received(:close)
    expect(pid_ns).to have_received(:close)
  end
  # rubocop:enable RSpec/MessageSpies

  it 'opens a rootfs beneath retained root and binds it to the expected inode' do
    root_stat = instance_double(File::Stat, dev: 1, ino: 10)
    mnt_stat = instance_double(File::Stat, dev: 2, ino: 20)
    current_root = instance_double(File, stat: root_stat, close: nil)
    current_mnt = instance_double(File, stat: mnt_stat, close: nil)
    expected_root = instance_double(File, stat: opened_root_dir.stat)

    allow(root_dir).to receive(:stat).and_return(root_stat)
    allow(net_ns).to receive(:stat).and_return(mnt_stat)
    allow(File).to receive(:open).with('/proc/123').and_return(proc_dir)
    allow(sys).to receive(:openat_io).with(proc_dir, 'ns/mnt')
                                     .and_return(net_ns, current_mnt, current_mnt)
    allow(sys).to receive(:openat_io).with(proc_dir, 'root')
                                     .and_return(root_dir, current_root, current_root)
    allow(sys).to receive(:open_beneath)
      .with(root_dir, 'srv/root')
      .and_return(opened_root_dir)

    identity = described_class.new(123, namespaces: [:mnt], root: true)
    opened = identity.open_root_path('/srv/root', expected: expected_root)

    expect(opened).to be(opened_root_dir)
    expect(sys).to have_received(:open_beneath).with(root_dir, 'srv/root')
    expect(current_root).to have_received(:close).twice
    expect(current_mnt).to have_received(:close).twice
  ensure
    identity&.close
    opened&.close
  end

  it 'releases the retained root without closing the remaining identity' do
    allow(File).to receive(:open).with('/proc/123').and_return(proc_dir)
    allow(sys).to receive(:openat_io).with(proc_dir, 'root').and_return(root_dir)
    allow(sys).to receive(:openat_io).with(proc_dir, 'ns/mnt').and_return(net_ns)

    identity = described_class.new(123, namespaces: [:mnt], root: true)
    identity.release_root

    expect(identity.root_dir).to be_nil
    expect(identity.files).to eq([pidfd, proc_dir, net_ns])
    expect(root_dir).to have_received(:close).once
    expect(pidfd).not_to have_received(:close)
    expect(proc_dir).not_to have_received(:close)
    expect(net_ns).not_to have_received(:close)
  ensure
    identity&.close
  end

  it 'rejects a peer which changed root after authentication' do
    held_stat = instance_double(File::Stat, dev: 1, ino: 10)
    changed_stat = instance_double(File::Stat, dev: 1, ino: 11)
    current_root = instance_double(File, stat: changed_stat, close: nil)
    expected_root = instance_double(File, stat: held_stat)

    allow(root_dir).to receive(:stat).and_return(held_stat)
    allow(File).to receive(:open).with('/proc/123').and_return(proc_dir)
    allow(sys).to receive(:openat_io)
      .with(proc_dir, 'root')
      .and_return(root_dir, current_root)
    allow(sys).to receive(:open_beneath)

    identity = described_class.new(123, root: true)

    expect do
      identity.open_root_path('/srv/root', expected: expected_root)
    end.to raise_error(Errno::ESTALE, /changed root/)
    expect(sys).not_to have_received(:open_beneath)
  ensure
    identity&.close
  end

  it 'rejects a peer which changed mount namespace after authentication' do
    root_stat = instance_double(File::Stat, dev: 1, ino: 10)
    held_mnt_stat = instance_double(File::Stat, dev: 2, ino: 20)
    changed_mnt_stat = instance_double(File::Stat, dev: 2, ino: 21)
    current_root = instance_double(File, stat: root_stat, close: nil)
    current_mnt = instance_double(File, stat: changed_mnt_stat, close: nil)
    expected_root = instance_double(File, stat: root_stat)

    allow(root_dir).to receive(:stat).and_return(root_stat)
    allow(net_ns).to receive(:stat).and_return(held_mnt_stat)
    allow(File).to receive(:open).with('/proc/123').and_return(proc_dir)
    allow(sys).to receive(:openat_io)
      .with(proc_dir, 'root')
      .and_return(root_dir, current_root)
    allow(sys).to receive(:openat_io)
      .with(proc_dir, 'ns/mnt')
      .and_return(net_ns, current_mnt)
    allow(sys).to receive(:open_beneath)

    identity = described_class.new(123, namespaces: [:mnt], root: true)

    expect do
      identity.open_root_path('/srv/root', expected: expected_root)
    end.to raise_error(Errno::ESTALE, /changed mount namespace/)
    expect(sys).not_to have_received(:open_beneath)
  ensure
    identity&.close
  end

  it 'rejects an exited peer without resolving a reused numeric PID' do
    expected_root = instance_double(File)

    allow(sys).to receive(:pidfd_alive?).with(pidfd).and_return(true, true, false)
    allow(File).to receive(:open).with('/proc/123').and_return(proc_dir)
    allow(sys).to receive(:openat_io).with(proc_dir, 'root').and_return(root_dir)
    allow(File).to receive(:open).with('/proc/123/root/srv/root', anything)

    identity = described_class.new(123, root: true)

    expect do
      identity.open_root_path('/srv/root', expected: expected_root)
    end.to raise_error(Errno::ESRCH)
    expect(File).not_to have_received(:open).with('/proc/123/root/srv/root', anything)
  ensure
    identity&.close
  end

  it 'closes the pidfd when the process has already exited' do
    allow(sys).to receive(:pidfd_alive?).with(pidfd).and_return(false)
    allow(File).to receive(:open).with('/proc/123').and_return(proc_dir)

    expect do
      described_class.new(123, namespaces: [:net])
    end.to raise_error(Errno::ESRCH)

    expect(File).to have_received(:open).with('/proc/123')
    expect(pidfd).to have_received(:close)
    expect(proc_dir).to have_received(:close)
  end

  it 'reports a closed identity as dead without polling its pidfd' do
    allow(File).to receive(:open).with('/proc/123').and_return(proc_dir)

    identity = described_class.new(123)
    identity.close

    expect(identity).not_to be_alive
    expect(sys).to have_received(:pidfd_alive?).with(pidfd).twice
  end

  it 'duplicates the held identity without reopening its numeric PID' do
    allow(OsCtl::Lib::Sys).to receive(:new).and_call_original

    identity = described_class.new(Process.pid, namespaces: [:mnt], root: true)
    copy = identity.duplicate
    original_fds = identity.files.map(&:fileno)
    copied_fds = copy.files.map(&:fileno)

    identity.close

    expect(copied_fds).not_to eq(original_fds)
    expect(copy).to be_alive
    expect(copy.start_time_ticks).to be_positive
    expect(copy.namespace(:mnt)).not_to be_closed
    expect(copy.root_dir).not_to be_closed
  ensure
    identity&.close
    copy&.close
  end

  it 'rejects symlink traversal and a substituted expected rootfs' do
    allow(OsCtl::Lib::Sys).to receive(:new).and_call_original

    with_tmpdir do |dir|
      expected_path = File.join(dir, 'expected')
      expected_child_path = File.join(expected_path, 'child')
      substituted_path = File.join(dir, 'substituted')
      symlink_path = File.join(dir, 'through-link')
      FileUtils.mkdir_p(expected_child_path)
      FileUtils.mkdir_p(substituted_path)
      File.symlink(expected_path, symlink_path)

      expected = File.open(expected_child_path)
      identity = described_class.new(Process.pid, namespaces: [:mnt], root: true)

      expect do
        identity.open_root_path(File.join(symlink_path, 'child'), expected:)
      end.to raise_error(Errno::ELOOP)

      expect do
        identity.open_root_path(substituted_path, expected:)
      end.to raise_error(Errno::EXDEV)
    ensure
      expected&.close
      identity&.close
    end
  end

  it 'rejects a peer which chroots after its root was retained' do
    allow(OsCtl::Lib::Sys).to receive(:new).and_call_original

    with_tmpdir do |dir|
      changed_root = File.join(dir, 'changed-root')
      FileUtils.mkdir_p(changed_root)
      command_r, command_w = IO.pipe
      status_r, status_w = IO.pipe

      child = Process.fork do
        command_w.close
        status_r.close
        status_w.puts('ready')
        status_w.flush
        command_r.gets
        begin
          Dir.chroot(changed_root)
        rescue Errno::EPERM => e
          status_w.puts("unsupported:#{e.class.name}")
          status_w.flush
          exit!(0)
        end
        Dir.chdir('/')
        status_w.puts('changed')
        status_w.flush
        command_r.gets
        exit!(0)
      end
      command_r.close
      status_w.close
      expect(status_r.gets).to eq("ready\n")

      identity = described_class.new(child, namespaces: [:mnt], root: true)
      expected = File.open('/')
      command_w.puts('change')
      change_status = status_r.gets
      skip('chroot requires CAP_SYS_CHROOT') if change_status == "unsupported:Errno::EPERM\n"
      expect(change_status).to eq("changed\n")

      expect do
        identity.open_root_path('/', expected:)
      end.to raise_error(Errno::ESTALE, /changed root/)
    ensure
      begin
        command_w&.puts('exit') unless command_w&.closed?
      rescue IOError, SystemCallError
        nil
      end
      command_w&.close
      status_r&.close
      Process.waitpid(child) if child
      expected&.close
      identity&.close
    end
  end

  it 'rejects a peer which changes mount namespace after authentication' do
    allow(OsCtl::Lib::Sys).to receive(:new).and_call_original

    command_r, command_w = IO.pipe
    status_r, status_w = IO.pipe
    child = Process.fork do
      command_w.close
      status_r.close
      status_w.puts('ready')
      status_w.flush
      command_r.gets
      begin
        OsCtl::Lib::Sys.new.unshare_ns(OsCtl::Lib::Sys::CLONE_NEWNS)
      rescue Errno::EPERM => e
        status_w.puts("unsupported:#{e.class.name}")
        status_w.flush
        exit!(0)
      end
      status_w.puts('changed')
      status_w.flush
      command_r.gets
      exit!(0)
    end
    command_r.close
    status_w.close
    expect(status_r.gets).to eq("ready\n")

    identity = described_class.new(child, namespaces: [:mnt], root: true)
    expected = File.open('/')
    command_w.puts('change')
    change_status = status_r.gets
    skip('mount namespace unshare is not permitted') if change_status == "unsupported:Errno::EPERM\n"
    expect(change_status).to eq("changed\n")

    expect do
      identity.open_root_path('/', expected:)
    end.to raise_error(Errno::ESTALE, /changed mount namespace/)
  ensure
    begin
      command_w&.puts('exit') unless command_w&.closed?
    rescue IOError, SystemCallError
      nil
    end
    command_w&.close
    status_r&.close
    Process.waitpid(child) if child
    expected&.close
    identity&.close
  end

  it 'reads environment only through the held proc directory' do
    allow(OsCtl::Lib::Sys).to receive(:new).and_call_original
    identity = described_class.new(Process.pid)

    expect(identity.environment_variable('HOME')).to eq(Dir.home)
    expect(identity.environment_variable('OSCTLD_MISSING_SPEC_VALUE')).to be_nil
  ensure
    identity&.close
  end

  it 'reads ancestry and cgroups through the held proc directory' do
    allow(OsCtl::Lib::Sys).to receive(:new).and_call_original

    current = described_class.new(Process.pid)
    parent = described_class.new(Process.ppid)
    grandparent = described_class.new(parent.parent_pid)

    expect(current.parent_pid).to eq(Process.ppid)
    expect(current.start_time_ticks).to be_positive
    expect(current.cgroup_paths).not_to be_empty
    expect(current.descendant_of?(parent)).to be(true)
    expect(current.descendant_of?(current)).to be(false)
    expect(current.descendant_at_depth?(parent, 1)).to be(true)
    expect(current.descendant_at_depth?(grandparent, 2)).to be(true)
    expect(current.descendant_at_depth?(parent, 2)).to be(false)
    expect(current.descendant_at_depth?(grandparent, 1)).to be(false)
    expect(current.descendant_at_depth?(parent, 0)).to be(false)
    expect(current.direct_child_of?(parent)).to be(true)
  ensure
    current&.close
    parent&.close
    grandparent&.close
  end

  it 'requires every cgroup hierarchy to remain in the expected subtree' do
    identity = described_class.allocate
    allow(identity).to receive(:read_proc_file).with('cgroup').and_return(<<~CGROUP)
      2:cpu,cpuacct:/osctl/pool.tank/ct.ct1/user-owned/lxc.payload.ct1
      3:memory:/foreign/ct.ct1
    CGROUP

    expect(
      identity.in_cgroup_subtree?('/osctl/pool.tank/ct.ct1/user-owned')
    ).to be(false)
  end

  it 'roots model-relative cgroup paths at the cgroup hierarchy root' do
    identity = described_class.allocate
    allow(identity).to receive(:read_proc_file).with('cgroup').and_return(<<~CGROUP)
      2:cpu,cpuacct:/osctl/pool.tank/ct.ct1/user-owned
      0::/osctl/pool.tank/ct.ct1/user-owned/lxc.payload.ct1
    CGROUP

    expect(
      identity.in_cgroup_subtree?('osctl/pool.tank/ct.ct1')
    ).to be(true)
  end

  it 'uses component boundaries when checking cgroup ancestry' do
    identity = described_class.allocate
    allow(identity).to receive(:read_proc_file).with('cgroup').and_return(<<~CGROUP)
      0::/osctl/pool.tank/ct.ct10/user-owned
    CGROUP

    expect(
      identity.in_cgroup_subtree?('/osctl/pool.tank/ct.ct1')
    ).to be(false)
  end

  it 'rejects a substituted pidfd' do
    allow(OsCtl::Lib::Sys).to receive(:new).and_call_original
    identity = described_class.new(Process.pid)
    original_pidfd = identity.pidfd
    identity.instance_variable_set(:@pidfd, File.open(File::NULL))

    expect do
      identity.authenticate!(cgroup_path: '/')
    end.to raise_error(Errno::ESRCH)
  ensure
    substituted_pidfd = identity&.pidfd
    substituted_pidfd&.close unless substituted_pidfd.equal?(original_pidfd)
    identity&.instance_variable_set(:@pidfd, original_pidfd)
    identity&.close
  end

  it 'rejects substituted proc, root, and mount namespace descriptors' do
    allow(OsCtl::Lib::Sys).to receive(:new).and_call_original
    identity = described_class.new(Process.pid, namespaces: [:mnt], root: true)
    original_proc_dir = identity.proc_dir
    original_root_dir = identity.root_dir
    original_mnt_ns = identity.namespace(:mnt)

    identity.instance_variable_set(:@proc_dir, File.open('/'))
    expect do
      identity.authenticate!(cgroup_path: '/')
    end.to raise_error(Errno::ESTALE, /proc descriptor was substituted/)

    identity.instance_variable_get(:@proc_dir).close
    identity.instance_variable_set(:@proc_dir, original_proc_dir)
    identity.instance_variable_set(:@root_dir, File.open('/tmp'))
    expect do
      identity.authenticate!(cgroup_path: '/')
    end.to raise_error(Errno::ESTALE, /changed root/)

    identity.instance_variable_get(:@root_dir).close
    identity.instance_variable_set(:@root_dir, original_root_dir)
    identity.instance_variable_get(:@namespaces)[:mnt] = File.open(File::NULL)
    expect do
      identity.authenticate!(cgroup_path: '/')
    end.to raise_error(Errno::ESTALE, /changed mount namespace/)
  ensure
    substituted_mnt = identity&.instance_variable_get(:@namespaces)&.[](:mnt)
    substituted_mnt&.close unless substituted_mnt.equal?(original_mnt_ns)
    identity&.instance_variable_get(:@namespaces)&.[]=(:mnt, original_mnt_ns) if original_mnt_ns
    identity&.close
  end
end
