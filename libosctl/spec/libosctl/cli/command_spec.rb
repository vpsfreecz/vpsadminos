# frozen_string_literal: true

require 'spec_helper'
require 'libosctl/cli/command'

RSpec.describe OsCtl::Lib::Cli::Command do
  let(:command_class) do
    Class.new(described_class) do
      def check_args(*required, optional: [], strict: true)
        require_args!(*required, optional:, strict:)
      end
    end
  end

  it 'raises when a required argument is missing' do
    command = command_class.new({}, {}, [])

    expect do
      command.check_args(:id)
    end.to raise_error(GLI::BadCommandLine, 'missing argument <id>')
  end

  it 'raises on extra arguments in strict mode' do
    command = command_class.new({}, {}, %w[ct1 unexpected])

    expect do
      command.check_args(:id)
    end.to raise_error(GLI::BadCommandLine, 'unknown argument: unexpected')
  end

  it 'includes the option ordering hint when an extra argument looks like an option' do
    command = command_class.new({}, {}, %w[ct1 -v])

    expect do
      command.check_args(:id)
    end.to raise_error(
      GLI::BadCommandLine,
      'unknown argument: -v (note that options must come before arguments)'
    )
  end

  it 'allows optional arguments and non-strict parsing' do
    command = command_class.new({}, {}, %w[ct1 snapshot note])

    expect do
      command.check_args(:id, optional: [:snapshot], strict: false)
    end.not_to raise_error
  end
end
