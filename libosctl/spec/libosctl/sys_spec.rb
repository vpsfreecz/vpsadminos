# frozen_string_literal: true

require 'spec_helper'
require 'libosctl/sys'

RSpec.describe OsCtl::Lib::Sys do
  subject(:sys) { described_class.new }

  def invoke(method_name, positional_args, keyword_args)
    if keyword_args.empty?
      sys.public_send(method_name, *positional_args)
    else
      sys.public_send(method_name, *positional_args, **keyword_args)
    end
  end

  shared_examples 'simple Int wrapper' do |method_name, callee, positional_args, keyword_args, expected_args|
    it "delegates #{method_name} and raises on failure" do
      allow(described_class::Int).to receive(callee).with(*expected_args).and_return(0, -1)

      expect(invoke(method_name, positional_args, keyword_args)).to eq(0)

      allow(Fiddle).to receive(:last_error).and_return(Errno::EPERM::Errno)

      expect do
        invoke(method_name, positional_args, keyword_args)
      end.to raise_error(SystemCallError)
    end
  end

  it_behaves_like 'simple Int wrapper',
                  :setresuid, :setresuid,
                  [1000, 1001, 1002], {},
                  [1000, 1001, 1002]

  it_behaves_like 'simple Int wrapper',
                  :setresgid, :setresgid,
                  [1000, 1001, 1002], {},
                  [1000, 1001, 1002]

  it_behaves_like 'simple Int wrapper',
                  :move_mount, :mount,
                  ['/src', '/dst'], {},
                  ['/src', '/dst', 0, described_class::MS_MGC_VAL | described_class::MS_MOVE, 0]

  it_behaves_like 'simple Int wrapper',
                  :bind_mount, :mount,
                  ['/src', '/dst'], {},
                  ['/src', '/dst', 0, described_class::MS_MGC_VAL | described_class::MS_BIND, 0]

  it_behaves_like 'simple Int wrapper',
                  :rbind_mount, :mount,
                  ['/src', '/dst'], {},
                  ['/src', '/dst', 0, described_class::MS_MGC_VAL | described_class::MS_BIND | described_class::MS_REC, 0]

  it_behaves_like 'simple Int wrapper',
                  :mount_tmpfs, :mount,
                  ['/mnt'], { name: 'tmpfs-name', flags: described_class::MS_NODEV, options: 'size=64m' },
                  ['tmpfs-name', '/mnt', 'tmpfs', described_class::MS_NODEV, 'size=64m']

  it_behaves_like 'simple Int wrapper',
                  :mount_proc, :mount,
                  ['/proc'], {},
                  ['none', '/proc', 'proc', described_class::MS_MGC_VAL, 0]

  it_behaves_like 'simple Int wrapper',
                  :make_shared, :mount,
                  ['/mnt'], {},
                  ['none', '/mnt', 0, described_class::MS_SHARED, 0]

  it_behaves_like 'simple Int wrapper',
                  :make_rshared, :mount,
                  ['/mnt'], {},
                  ['none', '/mnt', 0, described_class::MS_REC | described_class::MS_SHARED, 0]

  it_behaves_like 'simple Int wrapper',
                  :make_slave, :mount,
                  ['/mnt'], {},
                  ['none', '/mnt', 0, described_class::MS_SLAVE, 0]

  it_behaves_like 'simple Int wrapper',
                  :make_rslave, :mount,
                  ['/mnt'], {},
                  ['none', '/mnt', 0, described_class::MS_REC | described_class::MS_SLAVE, 0]

  it_behaves_like 'simple Int wrapper',
                  :unmount, :umount2,
                  ['/mnt'], {},
                  ['/mnt', 0]

  it_behaves_like 'simple Int wrapper',
                  :unmount_lazy, :umount2,
                  ['/mnt'], {},
                  ['/mnt', described_class::Int::MNT_DETACH]

  it_behaves_like 'simple Int wrapper',
                  :chroot, :chroot,
                  ['/newroot'], {},
                  ['/newroot']

  it 'sets a namespace from a path and closes the file descriptor on success' do
    io = instance_double(File, fileno: 5, close: nil)

    allow(File).to receive(:open).with('/proc/123/ns/mnt').and_return(io)
    allow(OsCtl::Lib::Native).to receive(:setns).with(5, described_class::CLONE_NEWNS)

    expect(sys.setns_path('/proc/123/ns/mnt', described_class::CLONE_NEWNS)).to be_nil
    expect(io).to have_received(:close)
  end

  it 'closes the namespace file descriptor even when setns fails' do
    io = instance_double(File, fileno: 5, close: nil)

    allow(File).to receive(:open).with('/proc/123/ns/mnt').and_return(io)
    allow(OsCtl::Lib::Native).to receive(:setns).with(5, 0).and_raise(Errno::EINVAL)

    expect do
      sys.setns_path('/proc/123/ns/mnt', 0)
    end.to raise_error(Errno::EINVAL)

    expect(io).to have_received(:close)
  end

  it 'delegates setns_io to Native.setns' do
    io = instance_double(File, fileno: 7)

    allow(OsCtl::Lib::Native).to receive(:setns).with(7, described_class::CLONE_NEWNET)

    expect(sys.setns_io(io, described_class::CLONE_NEWNET)).to be_nil
  end

  it 'delegates unshare_ns to Native.unshare' do
    allow(OsCtl::Lib::Native).to receive(:unshare).with(described_class::CLONE_NEWIPC)

    expect(sys.unshare_ns(described_class::CLONE_NEWIPC)).to be_nil
  end

  it 'creates a syslog namespace with klogctl followed by unshare' do
    allow(described_class::Int).to receive(:klogctl).with(11, 'demo', 4).and_return(0)
    allow(described_class::Int).to receive(:unshare).with(0).and_return(0)

    expect(sys.create_syslogns('demo')).to eq(0)
    expect(described_class::Int).to have_received(:klogctl).with(11, 'demo', 4).ordered
    expect(described_class::Int).to have_received(:unshare).with(0).ordered
  end

  it 'rejects overlong syslog namespace tags' do
    expect do
      sys.create_syslogns('x' * (described_class::SYSLOGNS_MAX_TAG_BYTESIZE + 1))
    end.to raise_error(ArgumentError, /at most #{described_class::SYSLOGNS_MAX_TAG_BYTESIZE} bytes/)
  end

  it 'raises when creating a syslog namespace fails' do
    allow(described_class::Int).to receive(:klogctl).with(11, 'demo', 4).and_return(0)
    allow(described_class::Int).to receive(:unshare).with(0).and_return(-1)
    allow(Fiddle).to receive(:last_error).and_return(Errno::EPERM::Errno)

    expect { sys.create_syslogns('demo') }.to raise_error(SystemCallError)
  end

  it 'attaches to the syslog namespace of a process' do
    sys_class = Class.new(described_class) do
      attr_reader :setns_args

      def setns_path(path, nstype)
        @setns_args = [path, nstype]
      end
    end

    sys_instance = sys_class.new
    sys_instance.attach_syslogns(4321)

    expect(sys_instance.setns_args).to eq(['/proc/4321/ns/syslog', 0])
  end

  it 'syncs the filesystem using a tempfile-backed file descriptor and cleans it up' do
    tempfile = instance_double(Tempfile, fileno: 7, close: nil, unlink: nil)

    allow(Tempfile).to receive(:new).with('.syncfs', '/mnt').and_return(tempfile)
    allow(described_class::Int).to receive(:syncfs).with(7).and_return(0)

    expect(sys.syncfs('/mnt')).to eq(0)
    expect(tempfile).to have_received(:close)
    expect(tempfile).to have_received(:unlink)
  end

  it 'cleans up the tempfile when syncfs fails' do
    tempfile = instance_double(Tempfile, fileno: 7, close: nil, unlink: nil)

    allow(Tempfile).to receive(:new).with('.syncfs', '/mnt').and_return(tempfile)
    allow(described_class::Int).to receive(:syncfs).with(7).and_return(-1)
    allow(Fiddle).to receive(:last_error).and_return(Errno::EIO::Errno)

    expect { sys.syncfs('/mnt') }.to raise_error(SystemCallError)
    expect(tempfile).to have_received(:close)
    expect(tempfile).to have_received(:unlink)
  end
end
