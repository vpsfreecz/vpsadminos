# frozen_string_literal: true

require 'osctld/container_control/commands/exec'
require 'osctld/container_control/result'
require 'osctld/dist_config'
require 'stringio'

RSpec.describe OsCtld::ContainerControl::Commands::Exec do
  def build_ct(running:)
    lifecycle = Struct.new(:active_run_id) do
      def run(_run_id)
        {
          'resources' => {
            'lxc_monitor' => '/osctl/ct.ct1/runs/run-1/user-owned/monitor',
            'lxc_config' => '/var/lib/lxc/ct1/config.run-1'
          }
        }
      end
    end.new('run-1')
    Struct.new(:running, :lifecycle, keyword_init: true) do
      def running?
        running
      end
    end.new(running:, lifecycle:)
  end

  subject(:frontend) do
    Class.new(described_class::Frontend) do
      attr_accessor :exec_result, :cleanup_calls, :exec_calls, :mode_override,
                    :runner_opts_override

      def with_execution_mode(...)
        if mode_override
          yield(mode_override, runner_opts_override || {})
        else
          super
        end
      end

      def exec_runner(**opts)
        self.exec_calls ||= []
        exec_calls << opts
        exec_result
      end

      def cleanup_init_script
        self.cleanup_calls ||= 0
        self.cleanup_calls += 1
      end
    end.new(described_class, ct)
  end

  let(:running) { true }
  let(:ct) { build_ct(running:) }

  it 'uses running mode when the container is already up' do
    frontend.exec_result = OsCtld::ContainerControl::Result.new(true, data: 0)

    expect(frontend.execute(cmd: %w[id], stdin: nil, stdout: StringIO.new, stderr: StringIO.new)).to eq(0)
    call = frontend.exec_calls.first

    expect(call[:args]).to eq([:running, { cmd: %w[id] }])
    expect(call[:stdin]).to be_nil
    expect(call[:stdout]).to be_a(StringIO)
    expect(call[:stderr]).to be_a(StringIO)
    expect(call[:on_spawn]).to be_a(Proc)
    expect(call[:on_reap]).to be_a(Proc)
    expect(frontend.cleanup_calls).to eq(1)
  end

  it 'passes transient lifecycle runner options in stopped run mode' do
    ct.running = false
    frontend.mode_override = :run
    frontend.runner_opts_override = {
      run_id: 'run-2',
      lxc_config: '/var/lib/lxc/ct1/config.run-2'
    }
    frontend.exec_result = OsCtld::ContainerControl::Result.new(true, data: 0)

    frontend.execute(cmd: %w[id], run: true, stdin: nil, stdout: StringIO.new, stderr: StringIO.new)

    call = frontend.exec_calls.first

    expect(call[:args]).to eq([:run, { cmd: %w[id] }])
    expect(call[:run_id]).to eq('run-2')
    expect(call[:lxc_config]).to eq('/var/lib/lxc/ct1/config.run-2')
    expect(call[:stdin]).to be_nil
    expect(call[:stdout]).to be_a(StringIO)
    expect(call[:stderr]).to be_a(StringIO)
    expect(frontend.cleanup_calls).to eq(1)
  end

  it 'raises when exec is requested on a stopped container without run mode' do
    ct.running = false

    expect do
      frontend.execute(cmd: %w[id], stdin: nil, stdout: StringIO.new, stderr: StringIO.new)
    end.to raise_error(OsCtld::ContainerControl::Error, 'container not running')
  end
end
