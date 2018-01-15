module OsCtld
  module Assets::Definition
    class Scope
      attr_reader :assets

      def initialize
        @assets = []
      end

      def asset(type, path, opts = {}, &block)
        @assets << Assets.for_type(type).new(path, opts, &block)
      end

      Assets.types.each do |t|
        define_method(t) do |*args, &block|
          send(:asset, t, *args, &block)
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
