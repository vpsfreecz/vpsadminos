# frozen_string_literal: true

require 'osctld/process_identity'

# rubocop:disable RSpec/MultipleMemoizedHelpers

RSpec.describe OsCtld::ProcessIdentity do
  let(:sys) { instance_double(OsCtl::Lib::Sys) }
  let(:pidfd_stat) { instance_double(File::Stat, dev: 7, ino: 70) }
  let(:pidfd) { instance_double(IO, stat: pidfd_stat, closed?: false, close: nil) }
  let(:root_dir) { instance_double(File, closed?: false, close: nil) }
  let(:net_ns) { instance_double(File, closed?: false, close: nil) }
  let(:pid_ns) { instance_double(File, closed?: false, close: nil) }
  let(:proc_dir) do
    instance_double(
      File,
      fileno: 11,
      stat: instance_double(File::Stat, directory?: true, dev: 9, ino: 90),
      closed?: false,
      close: nil
    )
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
    expect(identity.proc_dir).to be(proc_dir)
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

  it 'closes the pidfd when the process has already exited' do
    allow(sys).to receive(:pidfd_alive?).with(pidfd).and_return(false)
    allow(File).to receive(:open).with('/proc/123').and_return(proc_dir)

    expect do
      described_class.new(123, namespaces: [:net])
    end.to raise_error(Errno::ESRCH)

    expect(File).to have_received(:open).with('/proc/123')
    expect(pidfd).to have_received(:close)
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

# rubocop:enable RSpec/MultipleMemoizedHelpers
