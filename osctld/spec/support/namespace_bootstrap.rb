# frozen_string_literal: true

require 'osctld/assets'
require 'osctld/lock_registry'

module OsCtld
  IdRange = Class.new unless const_defined?(:IdRange)
  Repository = Class.new unless const_defined?(:Repository)
  Container = Class.new unless const_defined?(:Container)
  Pool = Class.new unless const_defined?(:Pool)
  ThreadReaper = Class.new unless const_defined?(:ThreadReaper)

  module DB; end unless const_defined?(:DB)
  module Routing; end unless const_defined?(:Routing)
  module SendReceive; end unless const_defined?(:SendReceive)
  module SendReceive::Commands; end unless SendReceive.const_defined?(:Commands)
  module UserControl; end unless const_defined?(:UserControl)
  module UserControl::Commands; end unless UserControl.const_defined?(:Commands)
  module ContainerControl; end unless const_defined?(:ContainerControl)
  module ContainerControl::Utils; end unless ContainerControl.const_defined?(:Utils)
  module ContainerControl::Commands; end unless ContainerControl.const_defined?(:Commands)
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
  module Utils; end unless const_defined?(:Utils)
  module Mount; end unless const_defined?(:Mount)
  module NetInterface; end unless const_defined?(:NetInterface)
  module PrLimits; end unless const_defined?(:PrLimits)

  module Devices::V1; end unless Devices.const_defined?(:V1)
  module Devices::V2; end unless Devices.const_defined?(:V2)

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
