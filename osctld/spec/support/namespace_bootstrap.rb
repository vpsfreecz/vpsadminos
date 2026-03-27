# frozen_string_literal: true

require 'osctld/assets'
require 'osctld/lock_registry'

module OsCtld
  IdRange = Class.new unless const_defined?(:IdRange)
  Repository = Class.new unless const_defined?(:Repository)
  Container = Class.new unless const_defined?(:Container)
  ThreadReaper = Class.new unless const_defined?(:ThreadReaper)

  module DB; end unless const_defined?(:DB)
  module Routing; end unless const_defined?(:Routing)
  module SendReceive; end unless const_defined?(:SendReceive)
  module RunState; end unless const_defined?(:RunState)
  module Generic; end unless const_defined?(:Generic)
  module Eventd; end unless const_defined?(:Eventd)

  unless const_defined?(:Commands)
    module Commands
      module Event; end unless const_defined?(:Event)
    end
  end

  unless const_defined?(:AutoStart)
    module AutoStart
      unless const_defined?(:Plan)
        Plan = Class.new do
          def resize(_value); end

          def started? = false

          def stop; end
        end
      end
    end
  end

  unless const_defined?(:AutoStop)
    module AutoStop
      unless const_defined?(:Plan)
        Plan = Class.new do
          def resize(_value); end

          def clear; end

          def stop; end
        end
      end
    end
  end

  module CGroup; end unless const_defined?(:CGroup)
  module Devices; end unless const_defined?(:Devices)
  module Mount; end unless const_defined?(:Mount)
  module NetInterface; end unless const_defined?(:NetInterface)
  module PrLimits; end unless const_defined?(:PrLimits)

  unless const_defined?(:TrashBin)
    TrashBin = Class.new do
      def started? = false

      def stop; end
    end
  end

  unless const_defined?(:HintUpdater)
    HintUpdater = Class.new do
      def stop; end
    end
  end

  OsCtlRepo = Class.new unless const_defined?(:OsCtlRepo)
end

RSpec.configure do |config|
  config.before do
    allow(OsCtld::LockRegistry).to receive(:register)
  end
end
