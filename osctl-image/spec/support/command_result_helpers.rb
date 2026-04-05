# frozen_string_literal: true

module CommandResultHelpers
  def command_result(output = '', exitstatus: 0)
    OsCtl::Lib::SystemCommandResult.new(exitstatus, output)
  end
end

RSpec.configure do |config|
  config.include CommandResultHelpers
end
