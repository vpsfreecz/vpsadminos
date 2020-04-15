module OsCtld
  # Frontend is run from osctld in daemon mode, when it is running as root
  class ContainerControl::Frontend
    # @return [Class]
    attr_reader :command_class

    # @return [Container]
    attr_reader :ct

    # @param command_class [Class]
    # @param ct [Container]
    def initialize(command_class, ct)
      @command_class = command_class
      @ct = ct
    end

    # Implement this method
    # @param args [Array] command arguments
    def execute(*args)
      raise NotImplementedError
    end

    protected
    # @param args [Array] command arguments
    # @return [ContainerControl::Result]
    def pipe_runner(args: [])
      r, w = IO.pipe

      runner_opts = {
        pool: ct.pool.name,
        id: ct.id,
        lxc_home: ct.lxc_home,
        user_home: ct.user.homedir,
        log_file: ct.log_path,
      }

      pid = SwitchUser.fork_and_switch_to(
        ct.user.sysusername,
        ct.user.ugid,
        ct.user.homedir,
        ct.cgroup_path,
        prlimits: ct.prlimits.export,
      ) do
        r.close

        Process.setproctitle(
          "osctld: #{runner_opts[:pool]}:#{runner_opts[:id]} "+
          "#{command_class.name.split('::').last.downcase} runner"
        )

        runner = command_class::Runner.new(runner_opts)
        ret = runner.execute(*args)
        w.write(ret.to_json + "\n")

        exit
      end

      w.close

      begin
        ret = JSON.parse(r.readline, symbolize_names: true)
        Process.wait(pid)
        ContainerControl::Result.from_runner(ret)

      rescue EOFError
        Process.wait(pid)
        ContainerControl::Result.new(false, message: 'user runner failed')
      end
    end
  end
end
