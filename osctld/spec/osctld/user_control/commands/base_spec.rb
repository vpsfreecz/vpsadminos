# frozen_string_literal: true

require 'securerandom'
require 'osctld/user_control/command'
require 'osctld/user_control/commands/base'

RSpec.describe OsCtld::UserControl::Commands::Base do
  let(:handle) { :"spec_user_control_base_#{SecureRandom.hex(4)}" }
  let(:command_class) do
    current_handle = handle

    Class.new(described_class) do
      handle current_handle

      def execute
        ok
      end
    end
  end
  let(:user) { Object.new }
  let(:command) { command_class.new(user, {}) }

  it 'registers commands through UserControl::Command' do
    command_class

    expect(OsCtld::UserControl::Command.find(handle)).to be(command_class)
  end

  it 'recognizes containers owned by the calling user' do
    ct_class = Struct.new(:user, keyword_init: true)

    expect(command.send(:owns_ct?, ct_class.new(user: user))).to be(true)
    expect(command.send(:owns_ct?, ct_class.new(user: Object.new))).to be(false)
  end
end
