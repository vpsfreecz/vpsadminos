# frozen_string_literal: true

require 'osctld/container_control/commands/runscript'
require 'osctld/container_control/result'
require 'stringio'

RSpec.describe OsCtld::ContainerControl::Commands::Runscript do
  subject(:frontend) do
    Class.new(described_class::Frontend) do
      attr_accessor :cleanup_calls, :exec_calls, :script_file, :unlink_calls

      def with_execution_mode(...)
        yield(:running, {})
      end

      def copy_script(...)
        script_file
      end

      def exec_runner(**opts)
        self.exec_calls ||= []
        exec_calls << opts
        OsCtld::ContainerControl::Result.new(true, data: 0)
      end

      def unlink_file(path)
        self.unlink_calls ||= []
        unlink_calls << path
      end

      def cleanup_init_script
        self.cleanup_calls ||= 0
        self.cleanup_calls += 1
      end
    end.new(described_class, Object.new)
  end

  let(:script_file) do
    Class.new do
      attr_reader :path, :close_calls

      def initialize
        @path = '/rootfs/.runscript.sh'
        @close_calls = 0
      end

      def close
        @close_calls += 1
      end
    end.new
  end

  it 'cleans up the staged script after execution' do
    frontend.script_file = script_file

    ret = frontend.execute(
      script: '/host/script',
      args: [],
      stdin: nil,
      stdout: StringIO.new,
      stderr: StringIO.new
    )

    expect(ret).to eq(0)
    expect(frontend.exec_calls.first.fetch(:args)).to eq(
      [:running, { args: [], script: '/.runscript.sh' }]
    )
    expect(script_file.close_calls).to eq(1)
    expect(frontend.unlink_calls).to eq(['/rootfs/.runscript.sh'])
    expect(frontend.cleanup_calls).to eq(1)
  end
end
