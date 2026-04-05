# frozen_string_literal: true

module CliCommandHelpers
  def default_gopts
    {
      'build-scripts' => nil,
      'vpsadminos-dir' => nil
    }
  end

  def build_command(klass, args: [], opts: {}, gopts: {})
    klass.new(default_gopts.merge(gopts), opts, args)
  end
end

RSpec.configure do |config|
  config.include CliCommandHelpers
end
