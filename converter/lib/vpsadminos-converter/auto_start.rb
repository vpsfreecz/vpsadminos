module VpsAdminOS::Converter
  class AutoStart
    attr_accessor :enabled, :priority, :delay

    def initialize
      @enabled = false
      @priority = 10
      @delay = 5
    end

    def dump
      return nil unless enabled

      {
        'priority' => priority,
        'delay' => delay
      }
    end
  end
end
