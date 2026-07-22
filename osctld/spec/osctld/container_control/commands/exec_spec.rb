# frozen_string_literal: true

$:.unshift(File.expand_path('../../../fixtures/ruby_load_path', __dir__))

require 'osctld/container_control/commands/exec'
require 'osctld/container_control/result'
require 'osctld/dist_config'
require 'stringio'

RSpec.describe OsCtld::ContainerControl::Commands::Exec do
  def build_mounts
    Struct.new(:pruned, keyword_init: true) do
      def prune
        self.pruned = true
      end
    end.new(pruned: false)
  end

  def build_run_conf
    Struct.new(:name, :issued_lifecycle_starts, keyword_init: true) do
      def issue_lifecycle_start
        self.issued_lifecycle_starts += 1
        'transient-start-token'
      end
    end.new(name: 'run-conf', issued_lifecycle_starts: 0)
  end

  def build_ct(running:, mounts:, run_conf:)
    Struct.new(:running, :mounts, :run_conf, :ensure_calls, keyword_init: true) do
      def running?
        running
      end

      def current_state
        running? ? :running : :stopped
      end

      def ensure_run_conf
        self.ensure_calls += 1
      end
    end.new(running:, mounts:, run_conf:, ensure_calls: 0)
  end

  subject(:frontend) do
    Class.new(described_class::Frontend) do
      attr_accessor :exec_result, :cleanup_calls, :exec_calls

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
  let(:mounts) { build_mounts }
  let(:run_conf) { build_run_conf }
  let(:ct) { build_ct(running:, mounts:, run_conf:) }

  before do
    allow(OsCtld::DistConfig).to receive(:run)
  end

  it 'uses running mode when the container is already up' do
    frontend.exec_result = OsCtld::ContainerControl::Result.new(true, data: 0)

    expect(frontend.execute(cmd: %w[id], stdin: nil, stdout: StringIO.new, stderr: StringIO.new)).to eq(0)
    call = frontend.exec_calls.first

    expect(call[:args]).to eq([:running, { cmd: %w[id] }])
    expect(call[:stdin]).to be_nil
    expect(call[:stdout]).to be_a(StringIO)
    expect(call[:stderr]).to be_a(StringIO)
    expect(call[:lifecycle_start_token]).to be_nil
    expect(call[:reset_subtree_control]).to be(false)
    expect(run_conf.issued_lifecycle_starts).to eq(0)
    expect(frontend.cleanup_calls).to eq(1)
  end

  it 'prepares run mode for stopped containers when run is requested' do
    ct.running = false
    frontend.exec_result = OsCtld::ContainerControl::Result.new(true, data: 0)

    frontend.execute(cmd: %w[id], run: true, stdin: nil, stdout: StringIO.new, stderr: StringIO.new)

    expect(ct.ensure_calls).to eq(1)
    expect(mounts.pruned).to be(true)
    expect(OsCtld::DistConfig).to have_received(:run).with(run_conf, :pre_start)
    call = frontend.exec_calls.first

    expect(call[:args]).to eq([:run, { cmd: %w[id] }])
    expect(call[:stdin]).to be_nil
    expect(call[:stdout]).to be_a(StringIO)
    expect(call[:stderr]).to be_a(StringIO)
    expect(call[:lifecycle_start_token]).to eq('transient-start-token')
    expect(call[:reset_subtree_control]).to be(true)
    expect(run_conf.issued_lifecycle_starts).to eq(1)
    expect(frontend.cleanup_calls).to eq(1)
  end

  it 'raises when exec is requested on a stopped container without run mode' do
    ct.running = false

    expect do
      frontend.execute(cmd: %w[id], stdin: nil, stdout: StringIO.new, stderr: StringIO.new)
    end.to raise_error(OsCtld::ContainerControl::Error, 'container not running')
  end
end
