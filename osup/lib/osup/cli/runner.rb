module OsUp
  class Cli::Runner < Cli::Command
    def run
      require_args!('pool', 'migration dirname', 'action')

      m = Migration.load(OsUp.migration_dir, args[1])
      Process.setproctitle("osup: #{args[0]} #{m.id} up")

      $POOL = args[0]
      load(m.action_script(args[2]))
    end
  end
end
