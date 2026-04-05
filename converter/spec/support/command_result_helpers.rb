# frozen_string_literal: true

module CommandResultHelpers
  FakeCommandResult = Struct.new(:output, :exitstatus, keyword_init: true) do
    def success?
      exitstatus == 0
    end
  end

  def command_result(output = '', exitstatus: 0)
    FakeCommandResult.new(output:, exitstatus:)
  end
end

RSpec.configure do |config|
  config.include CommandResultHelpers
end
