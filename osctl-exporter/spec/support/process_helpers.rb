# frozen_string_literal: true

module ProcessHelpers
  def build_wait_status(exitstatus)
    instance_double(Process::Status, exitstatus:, success?: exitstatus == 0)
  end

  def stub_backticks(target, values)
    allow(target).to receive(:`).and_wrap_original do |_orig, cmd|
      values.fetch(cmd) { raise "unexpected backtick command #{cmd.inspect}" }
    end
  end
end

RSpec.configure do |config|
  config.include ProcessHelpers
end
