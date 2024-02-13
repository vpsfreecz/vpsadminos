require 'osctld/hook/base'

module OsCtld
  module Pool::Hooks
    class Base < Hook::Base
      # Register pool hook under a name
      # @param hook_name [Symbol]
      def self.pool_hook(hook_name)
        hook(Pool, hook_name, self)
      end

      # @return [Pool]
      attr_reader :pool

      def setup
        @pool = event_instance
      end

      protected

      def environment
        super.merge({
          'OSCTL_POOL_NAME' => pool.name,
          'OSCTL_POOL_DATASET' => pool.dataset,
          'OSCTL_POOL_STATE' => pool.state.to_s
        })
      end
    end

    class PreImport < Base
      pool_hook :pre_import
      blocking true
    end

    class PreAutoStart < Base
      pool_hook :pre_autostart
      blocking true
    end

    class PostImport < Base
      pool_hook :post_import
      blocking false
    end

    class PreExport < Base
      pool_hook :pre_export
      blocking true
    end

    class PostExport < Base
      pool_hook :post_export
      blocking false
    end
  end
end
