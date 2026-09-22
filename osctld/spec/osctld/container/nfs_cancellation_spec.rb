# frozen_string_literal: true

require 'osctld/container/nfs_cancellation'

RSpec.describe OsCtld::Container::NfsCancellation do
  subject(:cancellation) { described_class.new(ct) }

  let(:ct) { Struct.new(:id, :ident, :cgroup_path).new('ct1', 'tank:ct1', 'osctl/ct.ct1/user-owned') }

  after { cancellation.close }

  def with_proc_threads
    with_tmpdir do |root|
      FileUtils.mkdir_p(File.join(root, 'self'))
      File.symlink('/proc/self/fd', File.join(root, 'self/fd'))
      %w[123 124].each do |tid|
        path = File.join(root, '123/task', tid)
        FileUtils.mkdir_p(File.join(path, 'ns'))
        File.symlink('/proc/self/ns/net', File.join(path, 'ns/net'))
        File.write(File.join(path, 'cgroup'), "0::/osctl/ct.ct1/user-owned/lxc.payload.ct1\n")
      end
      scanner = described_class.new(ct, proc_root: root)
      scanner.instance_variable_set(:@owner, File.open('/proc/self/ns/user'))
      begin
        yield scanner, root
      ensure
        scanner.close
      end
    end
  end

  it 'captures namespaces of non-leader payload threads' do
    with_proc_threads do |scanner, root|
      File.write(File.join(root, '123/task/123/cgroup'), "0::/other\n")
      scanner.send(:capture_descendants)
      expect(scanner.instance_variable_get(:@netns).size).to eq(1)
    end
  end

  it 'tolerates a thread disappearing during namespace capture' do
    with_proc_threads do |scanner, root|
      File.unlink(File.join(root, '123/task/123/cgroup'))
      scanner.send(:capture_descendants)
      expect(scanner.instance_variable_get(:@netns).size).to eq(1)
    end
  end

  it 'does not cancel anything before capturing an authenticated namespace' do
    expect(cancellation.abort).to eq(0)
  end

  it 'accepts the payload and nested cgroups for cgroup v1 and v2' do
    with_tmpdir do |dir|
      [
        '0::/osctl/ct.ct1/user-owned/lxc.payload.ct1',
        '5:freezer:/osctl/ct.ct1/user-owned/lxc.payload.ct1/service',
        '5:devices,freezer:/osctl/ct.ct1/user-owned/lxc.payload.ct1'
      ].each do |line|
        File.write(File.join(dir, 'cgroup'), "#{line}\n")
        expect(cancellation.send(:member?, dir)).to be(true)
      end
    end
  end

  it 'does not reacquire container locks after capturing immutable run identity' do
    cancellation
    %i[ident id cgroup_path].each do |method|
      allow(ct).to receive(method).and_raise('container lock acquired under cancellation mutex')
    end

    with_tmpdir do |dir|
      File.write(File.join(dir, 'cgroup'), "0::/osctl/ct.ct1/user-owned/lxc.payload.ct1\n")
      expect(cancellation.send(:member?, dir)).to be(true)
      expect(cancellation.log_type).to eq('nfs-cancel=tank:ct1')
    end
  end

  it 'rejects a prefix collision, the monitor, and another container' do
    with_tmpdir do |dir|
      [
        '0::/osctl/ct.ct1/user-owned/lxc.payload.ct10',
        '0::/osctl/ct.ct1/user-owned/lxc.monitor.ct1',
        '0::/osctl/ct.ct2/user-owned/lxc.payload.ct2',
        '2:cpu:/osctl/ct.ct1/user-owned/lxc.payload.ct1',
        'malformed'
      ].each do |line|
        File.write(File.join(dir, 'cgroup'), "#{line}\n")
        expect(cancellation.send(:member?, dir)).to be(false)
      end
    end
  end

  it 'pins process identity through an open proc directory instead of reusing a PID' do
    cancellation.send(:with_process, Process.pid) do |path|
      expect(path).to match(%r{\A/proc/self/fd/[0-9]+\z})
      expect(File.read(File.join(path, 'stat')).split.first.to_i).to eq(Process.pid)
    end
  end

  it 'writes only NFS filesystem controls and tolerates removed instances' do
    with_tmpdir do |dir|
      %w[0:12 server-4 0:13 unrelated].each { |entry| Dir.mkdir(File.join(dir, entry)) }
      %w[0:12 server-4 unrelated].each do |entry|
        File.write(File.join(dir, entry, 'shutdown'), '0')
      end
      # Simulate the kernel removing an instance before the control is opened.
      allow(File).to receive(:open).and_call_original
      allow(File).to receive(:open).with(File.join(dir, '0:13', 'shutdown'), File::WRONLY)
                                   .and_raise(Errno::ENOENT)

      expect(cancellation.send(:cancel_filesystems, dir)).to eq(2)
      expect(File.read(File.join(dir, '0:12/shutdown'))).to eq("1\n")
      expect(File.read(File.join(dir, 'server-4/shutdown'))).to eq("1\n")
      expect(File.read(File.join(dir, 'unrelated/shutdown'))).to eq('0')
    end
  end

  it 'does not hide a shutdown control error' do
    with_tmpdir do |dir|
      Dir.mkdir(File.join(dir, '0:12'))
      allow(File).to receive(:open).with(File.join(dir, '0:12/shutdown'), File::WRONLY)
                                   .and_raise(Errno::EIO)

      expect { cancellation.send(:cancel_filesystems, dir) }.to raise_error(Errno::EIO)
    end
  end

  it 'compares both device and inode when checking namespace identity' do
    io = instance_double(IO, stat: Struct.new(:dev, :ino).new(4, 8))
    expect(cancellation.send(:same_namespace?, io, Struct.new(:dev, :ino).new(4, 8))).to be(true)
    expect(cancellation.send(:same_namespace?, io, Struct.new(:dev, :ino).new(5, 8))).to be(false)
  end

  it 'prefers namespace shutdown over individual filesystem cancellation' do
    with_tmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, 'net/nfs_client'))
      control = File.join(dir, 'net/nfs_client/shutdown')
      File.write(control, "0\n")
      FileUtils.mkdir_p(File.join(dir, '0:12'))
      File.write(File.join(dir, '0:12/shutdown'), "0\n")

      expect(cancellation.send(:cancel_namespace, dir)).to eq(1)
      expect(File.read(control)).to eq("1\n")
      expect(File.read(File.join(dir, '0:12/shutdown'))).to eq("0\n")
    end
  end

  it 'uses subtree shutdown only for an authenticated root network namespace' do
    with_tmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, 'net/nfs_client'))
      tree = File.join(dir, 'net/nfs_client/shutdown_tree')
      single = File.join(dir, 'net/nfs_client/shutdown')
      File.write(tree, "0\n")
      File.write(single, "0\n")

      expect(cancellation.send(:cancel_namespace, dir, subtree: true)).to eq(1)
      expect(File.read(tree)).to eq("1\n")
      expect(File.read(single)).to eq("0\n")
      File.write(tree, "0\n")
      expect(cancellation.send(:cancel_namespace, dir)).to eq(1)
      expect(File.read(tree)).to eq("0\n")
      expect(File.read(single)).to eq("1\n")
    end
  end

  it 'falls back to single-namespace shutdown when subtree shutdown is unavailable' do
    with_tmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, 'net/nfs_client'))
      control = File.join(dir, 'net/nfs_client/shutdown')
      File.write(control, "0\n")

      expect(cancellation.send(:cancel_namespace, dir, subtree: true)).to eq(1)
      expect(File.read(control)).to eq("1\n")
    end
  end

  it 'uses per-filesystem shutdown on older kernels' do
    with_tmpdir do |dir|
      %w[0:12 0:13].each do |entry|
        Dir.mkdir(File.join(dir, entry))
        File.write(File.join(dir, entry, 'shutdown'), "0\n")
      end
      expect(cancellation.send(:cancel_namespace, dir)).to eq(2)
    end
  end

  it 'releases retained handles and can be closed repeatedly' do
    reader, writer = IO.pipe
    cancellation.instance_variable_set(:@owner, reader)
    cancellation.instance_variable_set(:@netns, { [1, 2] => writer })
    cancellation.close
    cancellation.close
    expect(reader).to be_closed
    expect(writer).to be_closed
    expect(cancellation.abort).to eq(0)
  end

  it 'cannot reopen a closed run through a stale monitor reference' do
    cancellation.close
    allow(File).to receive(:open).and_call_original

    cancellation.capture(Process.pid)

    expect(File).not_to have_received(:open).with("/proc/#{Process.pid}")
    expect(cancellation.abort_if_exiting).to eq(0)
  end

  describe 'early init exit' do
    def with_retained_init
      with_tmpdir do |root|
        FileUtils.mkdir_p(File.join(root, 'self'))
        File.symlink('/proc/self/fd', File.join(root, 'self/fd'))
        path = File.join(root, '123')
        Dir.mkdir(path)
        File.write(File.join(path, 'status'), "NSpid:\t123\t1\n")
        FileUtils.mkdir_p(File.join(path, 'task/123'))
        File.write(File.join(path, 'task/123/stat'), "123 (init (test)) S 0 0 0 0 0 0\n")
        scanner_class = Class.new(described_class) do
          attr_reader :abort_calls

          def abort_locked
            @abort_calls = (@abort_calls || 0) + 1
          end
        end
        scanner = scanner_class.new(ct, proc_root: root)
        File.open(path) { |dir| scanner.send(:retain_init, path, dir) }
        yield scanner, path
      ensure
        scanner&.close
      end
    end

    it 'does not cancel a running init, but detects PF_EXITING before LXC events' do
      with_retained_init do |scanner, path|
        expect(scanner.abort_if_exiting).to eq(0)
        File.write(File.join(path, 'task/123/stat'), "123 (init (test)) D 0 0 0 0 0 4\n")
        expect(scanner.abort_if_exiting).to eq(1)
        expect(scanner.abort_if_exiting).to eq(0)
        expect(scanner.abort_calls).to eq(1)
      end
    end

    it 'checks the retained proc directory instead of a reused PID' do
      with_retained_init do |scanner, path|
        File.rename(path, "#{path}-old")
        Dir.mkdir(path)
        File.write(File.join(path, 'stat'), "123 (replacement) D 0 0 0 0 0 4\n")
        expect(scanner.abort_if_exiting).to eq(0)
        FileUtils.remove_entry(File.join("#{path}-old", 'task'))
        expect(scanner.abort_if_exiting).to eq(1)
      end
    end

    it 'does not cancel when only the init thread-group leader exits' do
      with_retained_init do |scanner, path|
        File.write(File.join(path, 'task/123/stat'), "123 (init) Z 0 0 0 0 0 4\n")
        FileUtils.mkdir_p(File.join(path, 'task/124'))
        File.write(File.join(path, 'task/124/stat'), "124 (init worker) S 0 0 0 0 0 0\n")
        expect(scanner.abort_if_exiting).to eq(0)
        File.write(File.join(path, 'task/124/stat'), "124 (init worker) D 0 0 0 0 0 4\n")
        expect(scanner.abort_if_exiting).to eq(1)
      end
    end

    it 'does not mistake a hook subprocess for init' do
      with_tmpdir do |path|
        File.write(File.join(path, 'status'), "NSpid:\t123\t8\n")
        File.open(path) { |dir| cancellation.send(:retain_init, path, dir) }
        expect(cancellation.abort_if_exiting).to eq(0)
      end
    end

    it 'releases the retained proc directory on close' do
      with_retained_init do |scanner, _path|
        retained = scanner.instance_variable_get(:@init_proc)
        scanner.close
        expect(retained).to be_closed
        expect(scanner.abort_if_exiting).to eq(0)
      end
    end
  end

  describe 'cancellation worker' do
    def run_worker(scan: -> {}, &block)
      worker_class = Class.new(described_class) do
        define_method(:capture_descendants, &scan)
        define_method(:cancel_namespaces, &block)
      end
      worker = worker_class.new(ct)
      worker.send(:cancel_in_worker)
    ensure
      worker&.close
    end

    it 'returns the completed namespace count' do
      expect(run_worker { 2 }).to eq(2)
    end

    it 'propagates errors reported by the child' do
      expect { run_worker { raise IOError, 'write failed' } }
        .to raise_error(RuntimeError, 'NFS cancellation failed: IOError: write failed')
    end

    it 'reports an incomplete response instead of waiting forever' do
      expect { run_worker { exit! } }.to raise_error(JSON::ParserError)
    end

    it 'bounds the wait and kills and reaps its own unresponsive child' do
      stub_const('OsCtld::Container::NfsCancellation::WORKER_TIMEOUT', 0.05)
      children = []
      reapers = []
      allow(OsCtld::SwitchUser).to receive(:fork).and_wrap_original do |original, **opts, &block|
        original.call(**opts, &block).tap { |pid| children << pid }
      end
      allow(Process).to receive(:detach).and_wrap_original do |original, pid|
        original.call(pid).tap { |reaper| reapers << reaper }
      end

      expect { run_worker { sleep(60) } }.to raise_error(described_class::WorkerTimeout)
      expect(children.size).to eq(1)
      expect(Process).to have_received(:detach).with(children.first)
      expect(reapers.first.join(5)).not_to be_nil
      expect(reapers.first.value.termsig).to eq(Signal.list.fetch('KILL'))
    end

    it 'bounds process scanning before any namespace write' do
      stub_const('OsCtld::Container::NfsCancellation::WORKER_TIMEOUT', 0.05)

      expect { run_worker(scan: -> { sleep(60) }) { 0 } }
        .to raise_error(described_class::WorkerTimeout)
    end

    it 'bounds the response size from a failing child' do
      expect { run_worker { raise 'x' * 70_000 } }
        .to raise_error(RuntimeError, 'NFS cancellation worker output is too large')
    end
  end
end
