module OsCtld
  module Lxcfs
    class Error < ::StandardError ; end
    class Timeout < Error ; end

    class WorkerNotFound < Error
      def initialize(name)
        super("worker #{name.inspect} not found")
      end
    end
  end
end
