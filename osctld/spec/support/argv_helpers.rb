# frozen_string_literal: true

module ArgvHelpers
  def with_argv(*argv)
    old_argv = ARGV.dup
    ARGV.replace(argv)
    yield
  ensure
    ARGV.replace(old_argv)
  end
end

RSpec.configure do |config|
  config.include ArgvHelpers
end
