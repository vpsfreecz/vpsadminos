# frozen_string_literal: true

module LXC
  LXC_ATTACH_SET_PERSONALITY = 0x0200

  class Container
    def attach(*); end
    def init_pid; end
    def running?; end
  end
end
