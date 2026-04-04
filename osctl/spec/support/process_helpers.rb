# frozen_string_literal: true

module ProcessHelpers
  def build_wait_status(exitstatus)
    instance_double(Process::Status, exitstatus:)
  end

  def with_argv(argv)
    old = ARGV.dup
    ARGV.replace(argv)
    yield
  ensure
    ARGV.replace(old)
  end

  def with_program_name(name)
    old = $0
    $0 = name
    yield
  ensure
    $0 = old
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
