# frozen_string_literal: true

module OutputCaptureHelpers
  def capture_output
    old_out = $stdout
    old_err = $stderr
    $stdout = StringIO.new
    $stderr = StringIO.new
    yield
    [$stdout.string, $stderr.string]
  ensure
    $stdout = old_out
    $stderr = old_err
  end

  def capture_stdout(&)
    capture_output(&).first
  end

  def capture_stderr(&)
    capture_output(&).last
  end
end

RSpec.configure do |config|
  config.include OutputCaptureHelpers
end
