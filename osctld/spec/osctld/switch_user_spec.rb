# frozen_string_literal: true

require 'osctld/switch_user'

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

    allow(described_class).to receive(:walk_fds).and_yield(5).and_yield(7)
    allow(IO).to receive(:new).with(5).and_return(fd5)
    allow(IO).to receive(:new).with(7).and_raise('fd 7 should not be closed')

    described_class.close_fds(except: [7])

    expect(fd5).to have_received(:close).once
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

  describe '.attach_namespace_if_present' do
    it 'joins an existing namespace path' do
      sys = namespace_sys

      allow(File).to receive(:exist?).and_call_original
      allow(File).to receive(:exist?).with('/proc/123/ns/tracing').and_return(true)

      described_class.send(:attach_namespace_if_present, sys, 123, 'tracing')

      expect(sys.setns_paths).to eq([['/proc/123/ns/tracing', 0]])
    end

    it 'ignores missing tracing namespace paths for compatibility with older kernels' do
      sys = namespace_sys

      allow(File).to receive(:exist?).and_call_original
      allow(File).to receive(:exist?).with('/proc/123/ns/tracing').and_return(false)

      described_class.send(:attach_namespace_if_present, sys, 123, 'tracing')

      expect(sys.setns_paths).to be_empty
    end

    it 'does nothing when no pid is provided' do
      sys = namespace_sys

      described_class.send(:attach_namespace_if_present, sys, nil, 'tracing')

      expect(sys.setns_paths).to be_empty
    end
  end
end
