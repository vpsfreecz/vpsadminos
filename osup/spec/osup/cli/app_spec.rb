# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsUp::Cli::App do
  it 'returns a configured CLI object' do
    expect { described_class.get }.not_to raise_error
  end

  it 'registers the expected top-level commands' do
    app = described_class.get
    top_level = app.commands.keys.map(&:to_s)
    completion_commands = app.commands[:'gen-completion'].commands.keys.map(&:to_s)

    expect(top_level).to include(
      'status',
      'check',
      'check-rollback',
      'init',
      'upgrade',
      'upgrade-all',
      'rollback',
      'rollback-all',
      'gen-completion',
      'run'
    )
    expect(completion_commands).to include('bash')
  end

  it 'routes status to the main command handler' do
    allow(OsCtl::Lib::Logger).to receive(:setup)
    handler = Class.new do
      attr_reader :called

      def status
        @called = true
      end
    end.new
    allow(OsUp::Cli::Main).to receive(:new).and_return(handler)

    described_class.get.run(%w[status])

    expect(handler.called).to be(true)
  end

  it 'routes gen-completion bash to the completion handler' do
    allow(OsCtl::Lib::Logger).to receive(:setup)
    handler = Class.new do
      attr_reader :called

      def gen_bash_completion
        @called = true
      end
    end.new
    allow(OsUp::Cli::Main).to receive(:new).and_return(handler)

    described_class.get.run(%w[gen-completion bash])

    expect(handler.called).to be(true)
  end
end
