# frozen_string_literal: true

$:.unshift(File.expand_path('../../../fixtures/ruby_load_path', __dir__))

require 'osctld/container_control/commands/runscript'
require 'osctld/container_control/result'
require 'osctld/dist_config'
require 'stringio'

RSpec.describe OsCtld::ContainerControl::Commands::Runscript do
  subject(:frontend) do
    Class.new(described_class::Frontend) do
      attr_accessor :exec_result, :exec_calls, :copied_script, :unlinked_paths,
                    :cleanup_calls

      def exec_runner(**opts)
        self.exec_calls ||= []
        exec_calls << opts
        exec_result
      end

      def copy_script(*)
        copied_script
      end

      def unlink_file(path)
        self.unlinked_paths ||= []
        unlinked_paths << path
      end

      def cleanup_init_script
        self.cleanup_calls ||= 0
        self.cleanup_calls += 1
      end
    end.new(described_class, ct)
  end

  let(:run_conf) do
    Struct.new(:issued_lifecycle_starts, keyword_init: true) do
      def issue_lifecycle_start
        self.issued_lifecycle_starts += 1
        'runscript-start-token'
      end
    end.new(issued_lifecycle_starts: 0)
  end
  let(:mounts) do
    Struct.new(:pruned, keyword_init: true) do
      def prune
        self.pruned = true
      end
    end.new(pruned: false)
  end
  let(:ct) do
    Struct.new(:mounts, :run_conf, :ensure_calls, :state_reads, keyword_init: true) do
      def current_state
        self.state_reads += 1
        :stopped
      end

      def ensure_run_conf
        self.ensure_calls += 1
        run_conf
      end
    end.new(mounts:, run_conf:, ensure_calls: 0, state_reads: 0)
  end
  let(:script) do
    Struct.new(:path, :close_calls, keyword_init: true) do
      def close
        self.close_calls += 1
      end
    end.new(path: '/host/transient.sh', close_calls: 0)
  end

  before do
    frontend.exec_result = OsCtld::ContainerControl::Result.new(true, data: 0)
    frontend.copied_script = script
    allow(OsCtld::DistConfig).to receive(:run)
  end

  it 'issues and transfers a lifecycle capability for stopped-container runscript' do
    stdout = StringIO.new
    stderr = StringIO.new

    expect(
      frontend.execute(
        script: '/source/script',
        args: ['--flag'],
        run: true,
        network: false,
        stdin: StringIO.new,
        stdout:,
        stderr:
      )
    ).to eq(0)

    expect(frontend.exec_calls.fetch(0)).to include(
      args: [:run, { args: ['--flag'], script: '/transient.sh' }],
      lifecycle_start_token: 'runscript-start-token',
      stdout:,
      stderr:,
      switch_extra_namespaces: true,
      reset_subtree_control: true
    )
    expect(run_conf.issued_lifecycle_starts).to eq(1)
    expect(ct.ensure_calls).to eq(1)
    expect(ct.state_reads).to eq(2)
    expect(mounts.pruned).to be(true)
    expect(OsCtld::DistConfig).to have_received(:run).with(run_conf, :pre_start)
    expect(script.close_calls).to eq(1)
    expect(frontend.unlinked_paths).to eq(['/host/transient.sh'])
    expect(frontend.cleanup_calls).to eq(1)
  end
end
