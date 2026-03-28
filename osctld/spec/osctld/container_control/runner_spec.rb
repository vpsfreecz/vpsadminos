# frozen_string_literal: true

require 'stringio'
require 'osctld/switch_user'
require 'osctld/container_control/runner'

RSpec.describe OsCtld::ContainerControl::Runner do
  subject(:runner) do
    described_class.new(
      pool: 'tank',
      id: 'ct1',
      lxc_home: '/var/lib/lxc',
      user_home: '/home/alice',
      log_file: '/tmp/ct.log',
      stdout: StringIO.new,
      stderr: StringIO.new
    )
  end

  around do |example|
    original_env = ENV.to_h
    example.run
    ENV.replace(original_env)
  end

  it 'keeps only TERM and the intended exec env variables' do
    ENV['TERM'] = 'xterm'
    ENV['BUNDLE_GEMFILE'] = '/tmp/Gemfile'

    runner.send(:setup_exec_env)

    expect(ENV.fetch('TERM')).to eq('xterm')
    expect(ENV.to_h.fetch('HOME')).to eq('/home/alice')
    expect(ENV.fetch('PATH')).to eq(OsCtld::SwitchUser::SYSTEM_PATH.join(':'))
    expect(ENV).not_to have_key('BUNDLE_GEMFILE')
  end

  it 'prepends the wrapper path for run-mode exec env' do
    runner.send(:setup_exec_run_env)

    expect(ENV.fetch('PATH')).to start_with('/run/wrappers/bin:')
  end

  it 'memoizes the LXC container instance' do
    container = Object.new
    allow(LXC::Container).to receive(:new).with('ct1', '/var/lib/lxc').and_return(container)

    expect(runner.send(:lxc_ct)).to be(container)
    expect(runner.send(:lxc_ct)).to be(container)
    expect(LXC::Container).to have_received(:new).once
  end
end
