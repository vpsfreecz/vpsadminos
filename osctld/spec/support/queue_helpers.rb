# frozen_string_literal: true

require 'timeout'

module QueueHelpers
  def pop_with_timeout(queue, timeout: 2)
    Timeout.timeout(timeout) { queue.pop }
  rescue Timeout::Error
    raise "queue pop timed out after #{timeout}s"
  end
end

RSpec.configure do |config|
  config.include QueueHelpers
end
