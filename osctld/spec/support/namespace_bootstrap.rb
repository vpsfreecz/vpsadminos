# frozen_string_literal: true

require 'osctld/assets'
require 'osctld/lock_registry'

module OsCtld
  IdRange = Class.new
  Repository = Class.new
  Container = Class.new

  module DB; end
  module Routing; end
  module SendReceive; end
  module RunState; end

  module AutoStart
    Plan = Class.new do
      def resize(_value); end

      def started? = false

      def stop; end
    end
  end

  module AutoStop
    Plan = Class.new do
      def resize(_value); end

      def clear; end

      def stop; end
    end
  end

  module CGroup; end
  module Devices; end
  module Mount; end
  module NetInterface; end
  module PrLimits; end

  TrashBin = Class.new do
    def started? = false

    def stop; end
  end

  HintUpdater = Class.new do
    def stop; end
  end
  OsCtlRepo = Class.new
end

RSpec.configure do |config|
  config.before do
    allow(OsCtld::LockRegistry).to receive(:register)
  end
end
