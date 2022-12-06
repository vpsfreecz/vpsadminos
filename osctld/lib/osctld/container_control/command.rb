module OsCtld
  class ContainerControl::Error < StandardError ; end

  class ContainerControl::UserRunnerError < ContainerControl::Error ; end

  # Container control is used to interact with LXC containers
  #
  # In order to work manipulate LXC containers, osctld has to fork and switch
  # to the container's system user. This class then provides an interface
  # for various actions that manipulate the LXC containers.
  #
  # Each command is a subclass of this class. It needs to define two classes:
  # `Frontend` as a subclass of {ContainerControl::Frontend} and `Runner`
  # as a subclass of {ContainerControl::Runner}. {ContainerControl::Command#run!}
  # invokes `Frontend` from osctld in daemon mode, where it is running as root.
  #
  # The frontend initiates the runner, which is run in a forked process
  # and as a different user, e.g. using {ContainerControl::Frontend#exec_runner}
  # or {ContainerControl::Frontend#fork_runner}. The runner can return data,
  # which the frontend can transform and return to the caller.
  class ContainerControl::Command
    # Call command frontend
    #
    # See the command for what arguments it accepts and what it returns.
    # @param ct [Container]
    # @param args [Hash] command arguments
    # @param kwargs [Hash] command arguments
    # @raise [ContainerControl::Error]
    def self.run!(ct, *args, **kwargs)
      f = self::Frontend.new(self, ct)
      ret = f.execute(*args, **kwargs)

      if ret.is_a?(ContainerControl::Result)
        if ret.ok?
          ret.data
        elsif ret.user_runner?
          raise ContainerControl::UserRunnerError, ret.message
        else
          raise ContainerControl::Error, ret.message
        end
      else
        ret
      end
    end
  end
end
