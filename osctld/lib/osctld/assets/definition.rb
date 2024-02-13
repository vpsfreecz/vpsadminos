require 'require_all'
require_rel '*.rb'

module OsCtld
  module Assets::Definition
    class Scope
      attr_reader :assets

      def initialize
        @assets = []
      end

      def asset(type, path, opts = {}, &)
        @assets << Assets.for_type(type).new(path, opts, &)
      end

      Assets.types.each do |t|
        define_method(t) do |*args, **kwargs, &block|
          send(:asset, t, *args, **kwargs, &block)
        end
      end
    end

    def define_assets(&block)
      scope = Scope.new
      block.call(scope)
      scope.assets
    end
  end
end
