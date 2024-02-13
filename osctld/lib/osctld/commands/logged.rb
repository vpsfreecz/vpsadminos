require 'osctld/commands/base'

module OsCtld
  # Command template for commands that are to be logged to pool's history
  #
  # When logging to history, we need to know which pool the command works with.
  # {#find} should return an object that responds to `pool`, or raise exception.
  # {#execute} is then called with the return value of {#find} as the first
  # argument. If {#execute} returns success, the command will be logged.
  class Commands::Logged < Commands::Base
    def base_execute
      obj = find

      pool = if obj.is_a?(Pool)
               obj
             else
               obj.pool
             end

      ret = execute(obj)

      if ret.is_a?(Hash) && ret[:status] && !indirect?
        History.log(pool, self.class.cmd, opts)
      end

      ret
    end

    def find
      raise NotImplementedError
    end
  end
end
