require 'osctld/commands/base'

module OsCtld
  class Commands::Container::RecoverState < Commands::Base
    handle :ct_recover_state

    def execute
      ct = DB::Containers.find(opts[:id], opts[:pool])
      return error('container not found') unless ct

      recover = proc do
        recovery = Container::Recovery.new(ct)
        ok(recovery.recover_state(run_id: opts[:run_id]))
      end

      if opts[:manipulation_lock] == 'ignore'
        recover.call
      else
        manipulate(ct, lifecycle: true, &recover)
      end
    rescue ArgumentError => e
      error(e.message)
    end
  end
end
