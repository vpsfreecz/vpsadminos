# frozen_string_literal: true

require 'spec_helper'
require 'libosctl/logger'

RSpec.describe OsCtl::Lib::Logger do
  before do
    described_class.instance_variable_set(:@logger, nil)
  end

  it 'sets up a stdout logger and exposes it with get' do
    output = capture_stdout do
      described_class.setup(:stdout)
      expect(described_class.get).to be_a(::Logger)
      described_class.log(:info, 'hello stdout')
    end

    expect(output).to include('hello stdout')
  end

  it 'logs to an arbitrary IO object' do
    io = StringIO.new

    described_class.setup(:io, io:)
    described_class.log(:warn, 'hello io')

    expect(io.string).to include('hello io')
  end

  it 'disables logging with the none logger' do
    described_class.setup(:none)

    expect(described_class.get).to be_nil
    expect { described_class.log(:info, 'ignored') }.not_to raise_error
  end

  it 'sets up a syslog logger with the resolved facility' do
    require 'syslog/logger'

    fake = instance_double(Syslog::Logger)
    allow(Syslog::Logger).to receive(:new).and_return(fake)
    allow(fake).to receive(:info)

    described_class.setup(:syslog, name: 'libosctl-test', facility: 'daemon')
    described_class.log(:info, 'hello syslog')

    expect(Syslog::Logger).to have_received(:new).with('libosctl-test', Syslog::LOG_DAEMON)
    expect(fake).to have_received(:info).with('hello syslog')
  end

  it 'raises on an invalid logger type' do
    expect do
      described_class.setup(:bogus)
    end.to raise_error(RuntimeError, /unsupported logger type/)
  end
end
