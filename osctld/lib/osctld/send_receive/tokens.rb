require 'securerandom'
require 'singleton'

module OsCtld
  class SendReceive::Tokens
    include Singleton

    class << self
      %i[get register free find_container].each do |m|
        define_method(m) do |*args, &block|
          instance.send(m, *args, &block)
        end
      end
    end

    def initialize
      @mutex = Mutex.new
      @tokens = {}
    end

    # Allocate a new unique token
    # @return [String]
    def get
      sync do
        10.times do
          t = SecureRandom.hex(20)
          next if tokens.has_key?(t)

          tokens[t] = true
          return t
        end
      end

      raise 'unable to generate a unique token'
    end

    # Register an existing token in use
    def register(token)
      sync do
        if tokens.has_key?(token)
          raise "token #{token} already in use"
        end

        tokens[token] = true
      end
    end

    # Free allocated token
    # @param [String] token
    def free(token)
      sync { tokens.delete(token) }
    end

    # @param [String] token
    # @return [Container, nil]
    def find_container(token)
      return unless tokens.has_key?(token)

      DB::Containers.get.detect do |ct|
        ct.send_log && ct.send_log.token == token
      end
    end

    protected

    attr_reader :tokens, :mutex

    def sync(&)
      mutex.synchronize(&)
    end
  end
end
