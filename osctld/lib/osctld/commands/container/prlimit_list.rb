require 'osctld/commands/base'

module OsCtld
  class Commands::Container::PrLimitList < Commands::Base
    handle :ct_prlimit_list

    def execute
      ct = DB::Containers.find(opts[:id], opts[:pool])
      return error('container not found') unless ct

      ct.inclusively do
        ret = ct.prlimits.select do |limit|
          next(false) if opts[:limits] && !opts[:limits].include?(limit.name)
          true
        end.map(&:export)

        ok(ret)
      end
    end
  end
end
