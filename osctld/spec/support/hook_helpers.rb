# frozen_string_literal: true

module HookHelpers
  def write_executable(path, body = "#!/bin/sh\nexit 0\n")
    File.write(path, body)
    File.chmod(0o755, path)
    path
  end
end

RSpec.configure do |config|
  config.include HookHelpers
end
