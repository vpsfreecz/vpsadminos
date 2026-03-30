# frozen_string_literal: true

module ResetStateHelpers
  def reset_module_ivars(mod, *ivars)
    ivars.each do |ivar|
      mod.remove_instance_variable(ivar) if mod.instance_variable_defined?(ivar)
    end
  end
end

RSpec.configure do |config|
  config.include ResetStateHelpers
end
