# frozen_string_literal: true

module TempdirHelpers
  def with_tempdir(&)
    Dir.mktmpdir(&)
  end
end

RSpec.configure do |config|
  config.include TempdirHelpers
end
