# frozen_string_literal: true

module SingletonHelpers
  def reset_singleton(klass)
    klass.instance_variable_set(:@singleton__instance__, nil)
    klass.instance_variable_set(:@singleton__mutex__, Thread::Mutex.new)
  end
end

RSpec.configure do |config|
  config.include SingletonHelpers
end
