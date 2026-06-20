# frozen_string_literal: true

module OsCtld
  module ContainerControl
  end
end

$LOAD_PATH.unshift(File.expand_path('../../fixtures/ruby_load_path', __dir__))
require 'lxc'

require 'osctld/container_control/runner'

RSpec.describe OsCtld::ContainerControl::Runner do
  let(:runner_class) do
    Class.new(described_class) do
      def public_lxc_attach_wait(**opts, &)
        lxc_attach_wait(**opts, &)
      end

      def public_exitstatus(status)
        exitstatus(status)
      end

      def public_wait_for_lxc_attachable(**opts)
        wait_for_lxc_attachable(**opts)
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

  it 'uses the process exit status when the child exits normally' do
    status = instance_double(Process::Status, exited?: true, exitstatus: 7)

    expect(runner.public_exitstatus(status)).to eq(7)
  end

  it 'maps a signal termination to a shell-compatible status' do
    status = instance_double(Process::Status, exited?: false, signaled?: true, termsig: 9)

    expect(runner.public_exitstatus(status)).to eq(137)
  end

  it 'uses raw wait status returned by ruby-lxc attach wait mode' do
    expect(runner.public_exitstatus(7 << 8)).to eq(7)
  end

  it 'maps raw signal wait status returned by ruby-lxc attach wait mode' do
    expect(runner.public_exitstatus(9)).to eq(137)
  end

  it 'runs LXC attach in wait mode and returns its exit status' do
    lxc_ct = instance_double(LXC::Container)
    block_called = false

    allow(runner).to receive(:lxc_ct).and_return(lxc_ct)
    allow(lxc_ct).to receive(:attach) do |opts, &block|
      expect(opts).to include(wait: true, stdout: :out)
      expect(opts[:flags]).to eq(LXC::LXC_ATTACH_SET_PERSONALITY)
      block.call
      3 << 8
    end

    exit_status = runner.public_lxc_attach_wait(stdout: :out) do
      block_called = true
    end

    expect(block_called).to be(true)
    expect(lxc_ct).to have_received(:attach)
    expect(exit_status).to eq(3)
  end

  it 'waits until LXC reports an attachable init process' do
    lxc_ct = instance_double(LXC::Container, running?: true, init_pid: 123)

    allow(runner).to receive(:lxc_ct).and_return(lxc_ct)

    expect(runner.public_wait_for_lxc_attachable).to eq(123)
  end

  it 'times out when LXC has no attachable init process' do
    lxc_ct = instance_double(LXC::Container, running?: true, init_pid: nil)

    allow(runner).to receive(:lxc_ct).and_return(lxc_ct)

    expect(runner.public_wait_for_lxc_attachable(timeout: 0)).to be(false)
  end
end
