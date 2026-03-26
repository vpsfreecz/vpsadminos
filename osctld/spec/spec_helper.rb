# frozen_string_literal: true

require 'rspec'
require 'fileutils'
require 'tmpdir'
require 'json'

REPO_ROOT = File.expand_path('../..', __dir__)

$:.unshift(File.join(REPO_ROOT, 'osctld', 'lib'))
$:.unshift(File.join(REPO_ROOT, 'libosctl', 'lib'))
$:.unshift(File.join(REPO_ROOT, 'osctl-repo', 'lib'))
$:.unshift(File.join(REPO_ROOT, 'osup', 'lib'))

Dir[File.join(__dir__, 'support/**/*.rb')].each { |f| require f }

RSpec.configure do |config|
  config.disable_monkey_patching!

  config.expect_with(:rspec) do |c|
    c.syntax = :expect
  end

  config.mock_with(:rspec) do |mocks|
    mocks.verify_partial_doubles = true
  end

  config.shared_context_metadata_behavior = :apply_to_host_groups
  config.order = :random
  Kernel.srand config.seed
end
