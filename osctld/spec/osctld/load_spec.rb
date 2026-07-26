# frozen_string_literal: true

require 'open3'
require 'rbconfig'
require 'osctld/utils/container'

RSpec.describe OsCtld::Utils::Container do
  it 'loads container utilities before the container class in a fresh process' do
    script = <<~RUBY
      module OsCtld
        module Utils; end
      end

      require 'osctld/utils/container'

      if OsCtld.const_defined?(:Container, false)
        abort 'container utilities unexpectedly defined OsCtld::Container'
      end
    RUBY

    stdout, stderr, status = Open3.capture3(
      RbConfig.ruby,
      '-I',
      File.join(REPO_ROOT, 'osctld', 'lib'),
      '-e',
      script
    )

    expect(status).to be_success, <<~MESSAGE
      container utilities failed to load before OsCtld::Container
      stdout:
      #{stdout}
      stderr:
      #{stderr}
    MESSAGE
  end
end
