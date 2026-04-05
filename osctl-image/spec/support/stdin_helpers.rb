# frozen_string_literal: true

module StdinHelpers
  def with_stdin(str)
    old = $stdin
    $stdin = StringIO.new(str)
    yield
  ensure
    $stdin = old
  end
end

RSpec.configure do |config|
  config.include StdinHelpers
end
