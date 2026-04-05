# frozen_string_literal: true

module TempdirHelpers
  def with_tmpdir(&)
    Dir.mktmpdir('osctl-exportfs-spec', &)
  end
end

RSpec.configure do |config|
  config.include TempdirHelpers
end
