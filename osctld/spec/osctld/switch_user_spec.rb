# frozen_string_literal: true

require 'osctld/switch_user'

RSpec.describe OsCtld::SwitchUser do
  around do |example|
    original_env = ENV.to_h
    example.run
    ENV.replace(original_env)
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

  it 'runs the parent publication callback before releasing the child' do
    events = []
    reader = instance_double(IO, close: nil)
    writer = instance_double(IO, close: nil, closed?: false)
    allow(IO).to receive(:pipe).and_return([reader, writer])
    allow(OsCtld::CGroup).to receive(:mkpath_all)
    allow(described_class).to receive(:fork).and_return(123)
    allow(writer).to receive(:puts) { |value| events << value }

    pid = described_class.fork_and_switch_to(
      'alice',
      12_345,
      '/home/alice',
      '/osctl/test',
      before_continue: proc { |child_pid| events << "publish-#{child_pid}" }
    ) { raise 'child block is not run by this parent-side test' }

    expect(pid).to eq(123)
    expect(events).to eq(%w[publish-123 ready])
  end

  it 'cancels and reaps a child when parent-side publication fails' do
    reader = instance_double(IO, close: nil)
    writer = instance_double(IO, close: nil, closed?: false, puts: nil)
    allow(IO).to receive(:pipe).and_return([reader, writer])
    allow(OsCtld::CGroup).to receive(:mkpath_all)
    allow(described_class).to receive(:fork).and_return(123)
    allow(Process).to receive(:wait).with(123)

    expect do
      described_class.fork_and_switch_to(
        'alice',
        12_345,
        '/home/alice',
        '/osctl/test',
        before_continue: proc { raise 'publication failed' }
      ) { nil }
    end.to raise_error(RuntimeError, 'publication failed')

    expect(writer).to have_received(:puts).with('cancel')
    expect(Process).to have_received(:wait).with(123)
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
