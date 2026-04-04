# frozen_string_literal: true

module SingletonHelpers
  def fresh_singleton(klass, *, **)
    klass.send(:new, *, **)
  end
end

RSpec.configure do |config|
  config.include SingletonHelpers
end
