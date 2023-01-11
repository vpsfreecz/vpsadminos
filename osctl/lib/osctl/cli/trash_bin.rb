require 'osctl/cli/command'

module OsCtl::Cli
  class TrashBin < Command
    def dataset_add
      require_args!('dataset')
      osctld_fmt(:trash_bin_dataset_add, cmd_opts: {dataset: args[0]})
    end

    def prune
      require_args!(optional: %w(pool), strict: false)

      cmd_opts = {}
      cmd_opts[:pools] = args if args.any?

      osctld_fmt(:trash_bin_prune, cmd_opts: cmd_opts)
    end
  end
end
