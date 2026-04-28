# frozen_string_literal: true

require 'fileutils'
require 'tmpdir'

module OsCtld
  module ContainerControl
  end
end

require 'osctld/container_control/runner'

RSpec.describe OsCtld::ContainerControl::Runner do
  let(:runner_class) do
    Class.new(described_class) do
      def public_lxc_attach_wait(**opts, &block)
        lxc_attach_wait(**opts, &block)
      end

      def public_lxc_attach_config_without_prlimits
        lxc_attach_config_without_prlimits
      end

      def public_exitstatus(status)
        exitstatus(status)
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
    lxc_ct = double('lxc container')
    block_called = false

    allow(runner).to receive(:lxc_ct).and_return(lxc_ct)
    expect(lxc_ct).to receive(:clear_config_item).with('lxc.prlimit')
    expect(lxc_ct).to receive(:attach) do |opts, &block|
      expect(opts).to include(wait: true, stdout: :out)
      expect(opts[:flags] & LXC::LXC_ATTACH_MOVE_TO_CGROUP).to eq(0)
      block.call
      3 << 8
    end

    exit_status = runner.public_lxc_attach_wait(stdout: :out) do
      block_called = true
    end

    expect(block_called).to be(true)
    expect(exit_status).to eq(3)
  end

  it 'creates a transient LXC attach config without prlimits' do
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, 'ct1'))
      File.write(
        File.join(dir, 'ct1', 'config'),
        <<~CONFIG
          lxc.uts.name = ct1
          lxc.prlimit.nofile = 1024:1048576
          lxc.mount.auto = proc:mixed
        CONFIG
      )

      runner = runner_class.new(
        pool: 'tank',
        id: 'ct1',
        lxc_home: dir,
        user_home: '/home/test',
        log_file: '/tank/log/ct/ct1.log'
      )

      config = runner.public_lxc_attach_config_without_prlimits

      expect(File.read(config.path)).to eq(<<~CONFIG)
        lxc.uts.name = ct1
        lxc.mount.auto = proc:mixed
      CONFIG
    ensure
      if config
        path = config.path
        config.close
        File.unlink(path) if path && File.exist?(path)
      end
    end
  end

end
