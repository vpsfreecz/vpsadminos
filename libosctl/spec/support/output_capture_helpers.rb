# frozen_string_literal: true

module OutputCaptureHelpers
  def capture_stdout
    old = $stdout
    fake = StringIO.new
    $stdout = fake
    yield
    fake.string
  ensure
    $stdout = old
  end

  def capture_stderr
    old = $stderr
    fake = StringIO.new
    $stderr = fake
    yield
    fake.string
  ensure
    $stderr = old
  end
end

RSpec.configure do |config|
  config.include OutputCaptureHelpers
end
