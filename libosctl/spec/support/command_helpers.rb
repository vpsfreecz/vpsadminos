# frozen_string_literal: true

module CommandHelpers
  def command_result(exitstatus: 0, output: '')
    OsCtl::Lib::SystemCommandResult.new(exitstatus, output)
  end
end

RSpec.configure do |config|
  config.include CommandHelpers
end
