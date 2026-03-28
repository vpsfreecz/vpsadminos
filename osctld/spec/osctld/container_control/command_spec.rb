# frozen_string_literal: true

require 'osctld/container_control/command'
require 'osctld/container_control/result'

RSpec.describe OsCtld::ContainerControl::Command do
  let(:command_class) do
    Class.new(described_class) do
      const_set(
        :Frontend,
        Class.new do
          def initialize(*); end

          def execute; end
        end
      )
    end
  end
  let(:ct) { Object.new }

  it 'returns raw data from successful results' do
    frontend = instance_double(command_class::Frontend, execute: OsCtld::ContainerControl::Result.new(true, data: 12))
    allow(command_class::Frontend).to receive(:new).with(command_class, ct).and_return(frontend)

    expect(command_class.run!(ct)).to eq(12)
  end

  it 'raises container control errors for failed results' do
    frontend = instance_double(
      command_class::Frontend,
      execute: OsCtld::ContainerControl::Result.new(false, message: 'broken')
    )
    allow(command_class::Frontend).to receive(:new).with(command_class, ct).and_return(frontend)

    expect { command_class.run!(ct) }.to raise_error(OsCtld::ContainerControl::Error, 'broken')
  end

  it 'raises user runner errors separately' do
    frontend = instance_double(
      command_class::Frontend,
      execute: OsCtld::ContainerControl::Result.new(
        false,
        message: 'runner failed',
        user_runner: true
      )
    )
    allow(command_class::Frontend).to receive(:new).with(command_class, ct).and_return(frontend)

    expect { command_class.run!(ct) }.to raise_error(
      OsCtld::ContainerControl::UserRunnerError,
      'runner failed'
    )
  end
end
