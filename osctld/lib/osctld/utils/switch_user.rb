require 'json'
require 'tempfile'

module OsCtld
  module Utils::SwitchUser
    def ct_attach(ct, *args)
      {
        cmd: ::OsCtld.bin('osctld-ct-exec'),
        args: args.map(&:to_s),
        env: Hash[ENV.select { |k,_v| k.start_with?('BUNDLE') || k.start_with?('GEM') }],
        settings: {
          user: ct.user.sysusername,
          ugid: ct.user.ugid,
          homedir: ct.user.homedir,
          cgroup_path: ct.cgroup_path,
          prlimits: ct.prlimits.export,
        },
      }
    end

    # Run a command `cmd` within container `ct`
    # @param ct [Container]
    # @param cmd [Array<String>] command to execute
    # @param opts [Hash] options
    # @option opts [IO] :stdin
    # @option opts [IO] :stdout
    # @option opts [IO] :stderr
    # @option opts [Boolean] :run run the container if it is stopped?
    # @option opts [Boolean] :network setup network if the container is run?
    # @option opts [Array<Integer>, Symbol] :valid_rcs
    # @return [OsCtl::Lib::SystemCommandResult]
    def ct_syscmd(ct, cmd, opts = {})
      opts[:valid_rcs] ||= []
      log(:work, ct, cmd)

      ContainerControl::Commands::Syscmd.run!(ct, cmd, opts)
    end
  end
end
