require 'osctld/commands/base'

module OsCtld
  class Commands::Container::Wall < Commands::Base
    handle :ct_wall

    include OsCtl::Lib::Utils::Log

    def execute
      plan = ExecutionPlan.new

      DB::Containers.each_by_ids(opts[:ids], opts[:pool]) do |ct|
        plan << ct
      end

      plan.run do |ct|
        next unless ct.running?

        begin
          ContainerControl::Commands::Wall.run!(
            ct,
            message: opts[:message],
            banner: opts[:banner],
          )
        rescue ContainerControl::Error => e
          log(:info, 'ct-wall', "Error from ct #{ct.ident}: #{e.message}")
        end
      end

      plan.wait
      ok
    end
  end
end
