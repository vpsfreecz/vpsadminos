# frozen_string_literal: true

require 'spec_helper'
require 'vpsadminos-converter/cli/command'

RSpec.describe VpsAdminOS::Converter::Cli::Command do
  let(:command_class) do
    Class.new(described_class) do
      def perform
        :ok
      end
    end
  end

  it 'instantiates the command class and invokes the requested method' do
    command = instance_double(command_class, perform: :ok)
    handler = described_class.run(command_class, :perform)

    expect(command_class).to receive(:new)
      .with({ 'log-file' => nil }, { key: 'value' }, %w[arg])
      .and_return(command)

    expect(handler.call({ 'log-file' => nil }, { key: 'value' }, %w[arg])).to eq(:ok)
  end

  it 'configures logging to a file when requested' do
    io = StringIO.new
    allow(File).to receive(:open).with('/tmp/converter.log', 'a').and_return(io)
    expect(OsCtl::Lib::Logger).to receive(:setup).with(:io, io:)

    described_class.new({ 'log-file' => '/tmp/converter.log' }, {}, [])
  end

  it 'disables logging when no log file is given' do
    expect(OsCtl::Lib::Logger).to receive(:setup).with(:none)

    described_class.new({ 'log-file' => nil }, {}, [])
  end
end
