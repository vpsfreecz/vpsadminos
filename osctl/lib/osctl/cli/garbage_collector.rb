require 'osctl/cli/command'

module OsCtl::Cli
  class GarbageCollector < Command
    def prune
      require_args!(optional: %w[pool], strict: false)

      cmd_opts = {}
      cmd_opts[:pools] = args if args.any?

      osctld_fmt(:garbage_collector_prune, cmd_opts:)
    end
  end
end
