# frozen_string_literal: true

require 'osctld/switch_user'
require 'fcntl'
require 'socket'

RSpec.describe OsCtld::SwitchUser do
  around do |example|
    original_env = ENV.to_h
    example.run
    ENV.replace(original_env)
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

    described_class.switch_to('alice', 12_345, '/home/alice', '/sys/fs/cgroup/osctl')

    expect(ENV.to_h.fetch('HOME')).to eq('/home/alice')
    expect(ENV.to_h.fetch('USER')).to eq('alice')
    expect(ENV.to_h.fetch('XDG_RUNTIME_DIR')).to eq('/home/alice/.cache/lxc/run')
    expect(OsCtld::CGroup).to have_received(:attach_to_all).with(
      ['', 'sys', 'fs', 'cgroup', 'osctl']
    )
    expect(Process).to have_received(:groups=).with([12_345])
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
end
