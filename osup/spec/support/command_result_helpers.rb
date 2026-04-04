# frozen_string_literal: true

module CommandResultHelpers
  FakeCommandResult = Struct.new(:output, :exitstatus, keyword_init: true)

  def command_result(output = '', exitstatus: 0)
    FakeCommandResult.new(output: output, exitstatus: exitstatus)
  end
end

RSpec.configure do |config|
  config.include CommandResultHelpers
end
