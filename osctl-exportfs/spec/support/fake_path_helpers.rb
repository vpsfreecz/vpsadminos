# frozen_string_literal: true

require 'shellwords'

module FakePathHelpers
  def with_fake_path_command(command)
    with_tmpdir do |tmpdir|
      bin = File.join(tmpdir, 'nix/store/fake-direct-path/bin')
      marker = File.join(tmpdir, 'invocations')
      FileUtils.mkdir_p(bin)

      path = File.join(bin, command)
      File.write(
        path,
        <<~SCRIPT
          #!/bin/sh
          printf '%s %s\\n' "$0" "$*" >> #{marker.shellescape}
          exit 0
        SCRIPT
      )
      File.chmod(0o755, path)

      old_path = ENV.fetch('PATH', nil)
      ENV['PATH'] = bin

      begin
        yield bin, marker
      ensure
        ENV['PATH'] = old_path
      end
    end
  end
end

RSpec.configure do |config|
  config.include FakePathHelpers
end
