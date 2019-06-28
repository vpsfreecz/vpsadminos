module OsUp
  class Cli::Runner < Cli::Command
    def run
      require_args!('pool', 'dataset', 'migration dirname', 'action')

      m = Migration.load(OsUp.migration_dir, args[2])
      Process.setproctitle("osup: #{args[0]} #{m.id} up")

      $MIGRATION_ID = m.id
      $POOL = args[0]
      $DATASET = args[1]
      load(m.action_script(args[3]))
    end
  end
end
