# frozen_string_literal: true

require 'osctld/command'
require 'osctld/send_receive'
require 'osctld/send_receive/command'
require 'osctld/send_receive/commands/base'

RSpec.describe OsCtld::SendReceive::Command do
  around do |example|
    snapshot = OsCtld::Command.class_variable_get(:@@commands).transform_values(&:dup)
    example.run
  ensure
    OsCtld::Command.class_variable_set(:@@commands, snapshot)
  end

  it 'registers send-receive handlers in SendReceive::Command only' do
    klass = Class.new(OsCtld::SendReceive::Commands::Base) do
      handle :spec_receive_handler

      def execute
        ok
      end
    end

    expect(described_class.find(:spec_receive_handler)).to eq(klass)
    expect(
      OsCtld::Command.class_variable_get(:@@commands).fetch(OsCtld::Command, {})
    ).not_to have_key(:spec_receive_handler)
  end
end
