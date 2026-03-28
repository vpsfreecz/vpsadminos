# frozen_string_literal: true

module ProcessHelpers
  def build_wait_status(exitstatus)
    instance_double(Process::Status, exitstatus:)
  end
end

RSpec.configure do |config|
  config.include ProcessHelpers
end
