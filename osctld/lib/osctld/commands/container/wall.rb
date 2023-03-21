require 'osctld/commands/base'

module OsCtld
  class Commands::Container::Wall < Commands::Base
    handle :ct_wall

    include OsCtl::Lib::Utils::Log

    def execute
      cts = DB::Containers.get
      n = opts[:ids] ? opts[:ids].length : cts.length
      plan = ExecutionPlan.new

      cts.each do |ct|
        break if plan.length >= n
        next if opts[:ids] && !opts[:ids].include?(ct.id)
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
