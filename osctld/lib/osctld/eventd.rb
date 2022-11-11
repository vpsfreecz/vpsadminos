module OsCtld
  module Eventd
    class << self
      def instance
        @instance ||= Eventd::Manager.new
      end

      %i(start stop shutdown subscribe unsubscribe report).each do |m|
        define_method(m) do |*args, **kwargs, &block|
          instance.method(m).call(*args, **kwargs, &block)
        end
      end
    end
  end
end
