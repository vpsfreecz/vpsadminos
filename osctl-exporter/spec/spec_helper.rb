# frozen_string_literal: true

require 'rspec'
require 'json'
require 'stringio'
require 'time'
require 'rack/mock'
require 'English'

REPO_ROOT = File.expand_path('../..', __dir__)

$:.unshift(File.join(REPO_ROOT, 'osctl-exporter', 'lib'))
$:.unshift(File.join(REPO_ROOT, 'osctl-exportfs', 'lib'))
$:.unshift(File.join(REPO_ROOT, 'osctl', 'lib'))
$:.unshift(File.join(REPO_ROOT, 'libosctl', 'lib'))

Dir[File.join(__dir__, 'support/**/*.rb')].each { |f| require f }

require 'osctl/exporter'

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

  config.before do
    OsCtl::Exporter.instance_variable_set(:@registry, nil)
  end
end
