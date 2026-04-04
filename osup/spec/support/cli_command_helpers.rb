# frozen_string_literal: true

module CliCommandHelpers
  def default_gopts
    {
      debug: false,
      'dry-run' => false
    }
  end

  def build_command(klass, args: [], opts: {}, gopts: {})
    klass.new(default_gopts.merge(gopts), opts, args)
  end
end

RSpec.configure do |config|
  config.include CliCommandHelpers
end
