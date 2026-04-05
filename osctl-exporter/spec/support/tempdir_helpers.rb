# frozen_string_literal: true

module TempdirHelpers
  def with_tmpdir(&)
    Dir.mktmpdir('osctl-exporter-spec', &)
  end
end

RSpec.configure do |config|
  config.include TempdirHelpers
end
