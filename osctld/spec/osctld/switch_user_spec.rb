# frozen_string_literal: true

require 'osctld/switch_user'
require 'osctld/process_identity'
require 'fcntl'
require 'socket'
require 'timeout'

RSpec.describe OsCtld::SwitchUser do
  around do |example|
    original_env = ENV.to_h
    example.run
    ENV.replace(original_env)
  end

  def namespace_sys
    Class.new do
      attr_reader :setns_paths

      def initialize
        @setns_paths = []
      end

      def setns_path(path, flags)
        setns_paths << [path, flags]
      end
    end.new
  end

  def in_cleanup_child
    pid = Process.fork do
      yield
      exit!(0)
    rescue StandardError, RSpec::Expectations::ExpectationNotMetError => e
      warn("#{e.class}: #{e.message}")
      exit!(1)
    end

    expect(Process.wait2(pid).last.exitstatus).to eq(0)
  end

  it 'keeps requested descriptors and stdfds by default when forking' do
    closed = nil
    ran = false

    allow(described_class).to receive(:close_fds) do |except:|
      closed = except
    end
    allow(Process).to receive(:fork).and_yield.and_return(12)

    pid = described_class.fork(keep_fds: [9]) { ran = true }

    expect(pid).to eq(12)
    expect(closed).to eq([9, 0, 1, 2])
    expect(ran).to be(true)
  end

  it 'does not accept a numeric PID for privileged namespace attachment' do
    expect do
      described_class.switch_to('alice', 1234, '/', 'osctl/ct1', syslogns_pid: 1)
    end.to raise_error(ArgumentError, /unknown keyword/)
  end

  it 'maps unlimited prlimits to infinity' do
    prlimits = stub_const('OsCtld::PrLimits', Module.new)
    prlimits.const_set(:INFINITY, 9_999)
    prlimits.define_singleton_method(:resource_to_const) { |_resource| nil }
    prlimits.define_singleton_method(:set) { |_pid, _resource, _soft, _hard| nil }

    allow(OsCtld::PrLimits).to receive(:resource_to_const).with('nofile').and_return(:nofile)
    allow(OsCtld::PrLimits).to receive(:set)

    described_class.apply_prlimits(
      123,
      'nofile' => { soft: 'unlimited', hard: 1_024 }
    )

    expect(OsCtld::PrLimits).to have_received(:set).with(
      123,
      :nofile,
      9_999,
      1_024
    )
  end

  describe '.fork_and_switch_to' do
    before do
      stub_const('OsCtld::CGroup', Class.new do
        def self.mkpath_all(*); end
      end)
      allow(described_class).to receive(:switch_to)
      allow(described_class).to receive(:apply_prlimits)
    end

    def helper_fork(**opts, &block)
      described_class.fork_and_switch_to('alice', 1234, '/home/alice', 'osctl/ct1', **opts, &block)
    end

    def capture_helper_pids
      children = []
      allow(described_class).to receive(:fork).and_wrap_original do |original, **opts, &work|
        child = original.call(**opts) do
          work.call
        rescue StandardError
          exit!(1)
        end
        children << child
        child
      end
      children
    end

    def expect_failed_handoff(error, message = nil)
      children = capture_helper_pids
      Dir.mktmpdir('osctld-fork-failure') do |dir|
        marker = File.join(dir, 'workload')
        before_fds = Dir.children('/proc/self/fd').sort

        expect do
          Timeout.timeout(5) do
            helper_fork(prlimits: { 'nofile' => { soft: 1024, hard: 2048 } }) do
              File.write(marker, 'ran')
              exit!(0)
            end
          end
        end.to raise_error(error, message)

        expect(File).not_to exist(marker)
        expect(Dir.children('/proc/self/fd').sort).to eq(before_fds)
        children.each do |pid|
          expect { Process.waitpid(pid, Process::WNOHANG) }.to raise_error(Errno::ECHILD)
        end
      end
    end

    it 'waits for cleanup with over 1024 inherited FDs before lowering the child limit' do
      in_cleanup_child do
        inherited = Array.new(1100) { File.open(File::NULL) }
        entered_r, entered_w = IO.pipe
        release_r, release_w = IO.pipe
        result_r, result_w = IO.pipe
        progress = Queue.new
        children = capture_helper_pids
        pipes = []

        # The main test thread releases cleanup only after the helper parent
        # reaches its acknowledgement read. The old implementation instead
        # reaches apply_prlimits while cleanup is still held behind this gate.
        allow(described_class).to receive(:close_fds).and_wrap_original do |original, **opts|
          entered_w.puts('entered')
          raise 'cleanup gate closed' unless release_r.read(1) == '.'

          original.call(**opts)
        end
        allow(IO).to receive(:pipe).and_wrap_original do |original|
          pair = original.call
          pipes << pair
          if pipes.length == 2
            allow(pair.first).to receive(:readline).and_wrap_original do |readline|
              progress << :waiting_for_preparation
              readline.call
            end
          end
          pair
        end

        prlimit = Fiddle::Function.new(
          Fiddle::Handle::DEFAULT['prlimit'],
          [Fiddle::TYPE_INT, Fiddle::TYPE_INT, Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP],
          Fiddle::TYPE_INT
        )
        allow(described_class).to receive(:apply_prlimits) do |pid, limits|
          progress << :applying_limits
          limit = limits.fetch('nofile')
          ret = prlimit.call(pid, Process::RLIMIT_NOFILE, [limit[:soft], limit[:hard]].pack('L!L!'), nil)
          raise SystemCallError.new('prlimit', Fiddle.last_error) if ret != 0
        end

        worker = Thread.new do
          helper_fork(keep_fds: [result_w], prlimits: { 'nofile' => { soft: 1024, hard: 2048 } }) do
            result_w.puts(Process.getrlimit(:NOFILE).join(':'))
            exit!(0)
          end
        end
        worker.report_on_exception = false

        expect(Timeout.timeout(5) { entered_r.readline }).to eq("entered\n")
        expect(Timeout.timeout(5) { progress.pop }).to eq(:waiting_for_preparation)
        expect(described_class).not_to have_received(:apply_prlimits)
        release_w.write('.')
        pid = Timeout.timeout(5) { worker.value }

        expect(Timeout.timeout(5) { result_r.readline }).to eq("1024:2048\n")
        expect(Process.wait2(pid).last.exitstatus).to eq(0)
        expect(described_class).to have_received(:apply_prlimits).once
      ensure
        release_w&.close
        worker&.join(1)
        children&.each do |child|
          described_class.send(:reap_failed_fork, child)
        end
        [entered_r, entered_w, release_r, result_r, result_w, *inherited].compact.each do |io|
          io.close unless io.closed?
        end
      end
    end

    it 'reports child setup failure without applying limits or leaking descriptors or children' do
      in_cleanup_child do
        allow(described_class).to receive(:switch_to).and_raise('child setup failed')

        expect_failed_handoff(EOFError)
        expect(described_class).not_to have_received(:apply_prlimits)
      end
    end

    it 'rejects an invalid acknowledgement and reaps the waiting child' do
      in_cleanup_child do
        pipes = 0
        allow(IO).to receive(:pipe).and_wrap_original do |original|
          pair = original.call
          pipes += 1
          if pipes == 2
            allow(pair.last).to receive(:puts).with('prepared').and_wrap_original do |puts|
              puts.call('invalid')
            end
          end
          pair
        end

        expect_failed_handoff(RuntimeError, 'invalid child preparation acknowledgement')
        expect(described_class).not_to have_received(:apply_prlimits)
      end
    end

    it 'reaps only its failed helper when applying limits fails' do
      in_cleanup_child do
        other_r, other_w = IO.pipe
        unrelated = Process.fork do
          other_w.close
          other_r.read
          exit!(0)
        end
        other_r.close
        allow(described_class).to receive(:apply_prlimits).and_raise(Errno::EPERM, 'limit failure')

        expect_failed_handoff(Errno::EPERM, /limit failure/)
        expect(Process.waitpid(unrelated, Process::WNOHANG)).to be_nil
        other_w.close
        expect(Process.wait2(unrelated).last.exitstatus).to eq(0)
      ensure
        other_w&.close unless other_w&.closed?
        described_class.send(:reap_failed_fork, unrelated) if unrelated
      end
    end

    it 'reaps the child and preserves the error when the ready release fails' do
      in_cleanup_child do
        pipes = 0
        allow(IO).to receive(:pipe).and_wrap_original do |original|
          pair = original.call
          pipes += 1
          allow(pair.last).to receive(:puts).with('ready').and_raise(Errno::EPIPE) if pipes == 1
          pair
        end

        expect_failed_handoff(Errno::EPIPE)
      end
    end

    it 'closes the first pipe if creating the acknowledgement pipe fails' do
      in_cleanup_child do
        pipes = 0
        allow(IO).to receive(:pipe).and_wrap_original do |original|
          pipes += 1
          raise Errno::EMFILE if pipes == 2

          original.call
        end

        expect_failed_handoff(Errno::EMFILE)
      end
    end

    it 'closes helper pipes if the fork fails' do
      in_cleanup_child do
        allow(Process).to receive(:fork).and_raise(Errno::EAGAIN)

        expect_failed_handoff(Errno::EAGAIN)
      end
    end

    it 'does not signal a helper that has already been reaped' do
      allow(Process).to receive(:waitpid).with(123, Process::WNOHANG).and_raise(Errno::ECHILD)
      allow(Process).to receive(:kill)

      described_class.send(:reap_failed_fork, 123)

      expect(Process).not_to have_received(:kill)
    end
  end

  it 'closes only file descriptors that are not explicitly kept' do
    fd5 = instance_double(IO, close: nil)

    allow(ObjectSpace).to receive(:each_object).with(IO).and_return([].each)
    allow(described_class).to receive(:walk_fds).and_yield(5).and_yield(7)
    allow(IO).to receive(:new).with(5).and_return(fd5)
    allow(IO).to receive(:new).with(7).and_raise('fd 7 should not be closed')

    described_class.close_fds(except: [7])

    expect(fd5).to have_received(:close).once
  end

  it 'invalidates discarded Ruby owners before a descriptor can be reused' do
    File.open(File::NULL) do |original|
      in_cleanup_child do
        fd = original.fileno
        described_class.close_fds(except: [0, 1, 2])

        expect(original).to be_closed
        File.open(File::NULL) do |fresh|
          replacement = if fresh.fileno == fd
                          fresh
                        else
                          IO.for_fd(fresh.fcntl(Fcntl::F_DUPFD, fd))
                        end
          expect(replacement.fileno).to eq(fd)
          original.close
          GC.start
          expect { replacement.stat }.not_to raise_error
        ensure
          replacement&.close
        end
      end

      expect { original.stat }.not_to raise_error
    end
  end

  it 'invalidates a Ruby owner whose descriptor was already closed' do
    File.open(File::NULL) do |original|
      in_cleanup_child do
        IO.for_fd(original.fileno).close
        described_class.close_fds(except: [0, 1, 2])
        expect(original).to be_closed
      end
    end
  end

  it 'preserves requested IO and integer descriptors across garbage collection' do
    File.open(File::NULL) do |kept_io|
      File.open(File::NULL) do |kept_number|
        in_cleanup_child do
          described_class.close_fds(except: [0, 1, 2, kept_io, kept_number.fileno])
          GC.start

          expect { kept_io.stat }.not_to raise_error
          expect { kept_number.stat }.not_to raise_error
        end
      end
    end
  end

  it 'discards inherited output buffers without flushing them in the child' do
    reader, writer = IO.pipe
    writer.sync = false
    writer.write('parent-only')

    in_cleanup_child do
      described_class.close_fds(except: [0, 1, 2])
      expect(reader).to be_closed
      expect(writer).to be_closed
    end

    writer.close
    expect(reader.read).to eq('parent-only')
  ensure
    writer&.close unless writer&.closed?
    reader&.close
  end

  it 'invalidates every Ruby wrapper sharing a discarded descriptor' do
    File.open(File::NULL) do |original|
      alias_io = IO.for_fd(original.fileno, autoclose: false)

      in_cleanup_child do
        described_class.close_fds(except: [0, 1, 2])
        expect(original).to be_closed
        expect(alias_io).to be_closed

        File.open(File::NULL) do |replacement|
          original.close
          alias_io.close
          expect { replacement.stat }.not_to raise_error
        end
      end
    ensure
      alias_io&.close
    end
  end

  it 'still closes descriptors without a Ruby owner' do
    fd = IO.sysopen(File::NULL)

    in_cleanup_child do
      described_class.close_fds(except: [0, 1, 2])
      expect { IO.for_fd(fd).stat }.to raise_error(Errno::EBADF)
    end
  ensure
    IO.for_fd(fd).close if fd
  end

  it 'does not shut down sockets shared with the parent' do
    left, right = Socket.pair(:UNIX, :STREAM, 0)

    in_cleanup_child do
      described_class.close_fds(except: [0, 1, 2])
      expect(left).to be_closed
      expect(right).to be_closed
    end

    left.write('alive')
    expect(right.read(5)).to eq('alive')
  ensure
    left&.close
    right&.close
  end

  it 'preserves a duplex pipe writing descriptor without keeping its reader' do
    before = Dir.children('/proc/self/fd').map(&:to_i)

    IO.popen([RbConfig.ruby, '-e', 'STDOUT.write(STDIN.read(5).to_s)'], 'r+') do |stream|
      added = Dir.children('/proc/self/fd').map(&:to_i) - before
      write_fd = added.find do |fd|
        candidate = nil
        candidate = IO.for_fd(fd, autoclose: false)
        candidate.fcntl(Fcntl::F_GETFL).anybits?(Fcntl::O_WRONLY)
      rescue Errno::EBADF
        false
      ensure
        candidate&.close
      end
      expect(write_fd).not_to be_nil

      in_cleanup_child do
        described_class.close_fds(except: [0, 1, 2, write_fd])
        expect(stream.fileno).to eq(write_fd)
        stream.write('alive')
        stream.flush
      end

      expect(stream.read(5)).to eq('alive')
    end
  end

  it 'clears ruby, bundler, and gem environment variables' do
    ENV['RUBYOPT'] = '-w'
    ENV['BUNDLE_GEMFILE'] = '/tmp/Gemfile'
    ENV['GEM_HOME'] = '/tmp/gems'
    ENV['PATH'] = '/usr/bin'

    described_class.clear_ruby_env

    expect(ENV).not_to have_key('RUBYOPT')
    expect(ENV).not_to have_key('BUNDLE_GEMFILE')
    expect(ENV).not_to have_key('GEM_HOME')
    expect(ENV.fetch('PATH', nil)).to eq('/usr/bin')
  end

  it 'sets environment and switches to the target container user' do
    sys = instance_double(
      OsCtl::Lib::Sys,
      create_syslogns: nil,
      attach_syslogns: nil,
      setresgid: nil,
      setresuid: nil
    )

    cgroup = stub_const('OsCtld::CGroup', Module.new)
    cgroup.define_singleton_method(:attach_to_all) { |_path| nil }

    allow(OsCtld::CGroup).to receive(:attach_to_all)
    allow(Process).to receive(:groups=)
    allow(OsCtl::Lib::Sys).to receive(:new).and_return(sys)

    described_class.switch_to(
      'alice', 12_345, '/home/alice', '/sys/fs/cgroup/osctl', syslogns_tag: 'ct1-1234'
    )

    expect(ENV.to_h.fetch('HOME')).to eq('/home/alice')
    expect(ENV.to_h.fetch('USER')).to eq('alice')
    expect(ENV.to_h.fetch('XDG_RUNTIME_DIR')).to eq('/home/alice/.cache/lxc/run')
    expect(OsCtld::CGroup).to have_received(:attach_to_all).with(
      ['', 'sys', 'fs', 'cgroup', 'osctl']
    )
    expect(Process).to have_received(:groups=).with([12_345])
    expect(sys).to have_received(:create_syslogns).with('ct1-1234').once
    expect(sys).to have_received(:setresgid).with(12_345, 12_345, 12_345)
    expect(sys).to have_received(:setresuid).with(12_345, 12_345, 12_345)
  end

  it 'sets environment and switches to the target system user' do
    sys = instance_double(
      OsCtl::Lib::Sys,
      setresgid: nil,
      setresuid: nil
    )

    allow(Process).to receive(:groups=)
    allow(OsCtl::Lib::Sys).to receive(:new).and_return(sys)

    described_class.switch_to_system('alice', 12_345, 23_456, '/home/alice')

    expect(ENV.to_h.fetch('HOME')).to eq('/home/alice')
    expect(ENV.to_h.fetch('USER')).to eq('alice')
    expect(ENV.to_h.fetch('XDG_RUNTIME_DIR')).to eq('/home/alice/.cache/lxc/run')
    expect(Process).to have_received(:groups=).with([23_456])
    expect(sys).to have_received(:setresgid).with(23_456, 23_456, 23_456)
    expect(sys).to have_received(:setresuid).with(12_345, 12_345, 12_345)
  end

  describe '.create_syslogns' do
    let(:sys) { instance_double(OsCtl::Lib::Sys) }

    it 'keeps the requested tag when it is available' do
      allow(sys).to receive(:create_syslogns).with('ct1-1234').and_return(0)
      allow(SecureRandom).to receive(:hex)

      expect(described_class.send(:create_syslogns, sys, 'ct1-1234')).to eq(0)
      expect(SecureRandom).not_to have_received(:hex)
    end

    it 'creates a fresh namespace after each name collision' do
      tags = []
      allow(SecureRandom).to receive(:hex).with(2).and_return('0123', 'abcd')
      allow(sys).to receive(:create_syslogns) do |tag|
        tags << tag
        raise Errno::EEXIST if tags.length < 3

        0
      end

      expect(described_class.send(:create_syslogns, sys, 'ct1-1234')).to eq(0)
      expect(tags).to eq(%w[ct1-1234 ct1-0123 ct1-abcd])
      tags.each do |tag|
        expect(tag.bytesize).to be <= OsCtl::Lib::Sys::SYSLOGNS_MAX_TAG_BYTESIZE
        expect(tag).to match(/\A[A-Za-z0-9](?:[A-Za-z0-9_.-]*[A-Za-z0-9])?\z/)
      end
    end

    it 'bounds repeated collisions without attaching to an existing namespace' do
      allow(sys).to receive(:create_syslogns).and_raise(Errno::EEXIST)
      allow(sys).to receive(:attach_syslogns)
      allow(SecureRandom).to receive(:hex).with(2).and_return('0123')

      expect do
        described_class.send(:create_syslogns, sys, 'ct1-1234')
      end.to raise_error(Errno::EEXIST)

      expect(sys).to have_received(:create_syslogns).exactly(8).times
      expect(sys).not_to have_received(:attach_syslogns)
      expect(SecureRandom).to have_received(:hex).exactly(7).times
    end

    [Errno::EPERM, Errno::EACCES, Errno::EINVAL, Errno::EAGAIN].each do |error|
      it "preserves #{error} without retrying" do
        allow(sys).to receive(:create_syslogns).and_raise(error)
        allow(SecureRandom).to receive(:hex)

        expect do
          described_class.send(:create_syslogns, sys, 'ct1-1234')
        end.to raise_error(error)

        expect(sys).to have_received(:create_syslogns).once
        expect(SecureRandom).not_to have_received(:hex)
      end
    end
  end
end
