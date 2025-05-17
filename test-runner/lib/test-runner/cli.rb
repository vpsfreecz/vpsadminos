require 'test-runner'
require 'test-runner/cli/app'
require 'test-runner/cli/command'
require 'test-runner/cli/label_filters'
require 'test-runner/cli/tag_filters'

module TestRunner::Cli
  def self.run
    App.run
  end
end
