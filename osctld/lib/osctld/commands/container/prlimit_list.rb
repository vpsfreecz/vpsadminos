require 'osctld/commands/base'

module OsCtld
  class Commands::Container::PrLimitList < Commands::Base
    handle :ct_prlimit_list

    def execute
      ct = DB::Containers.find(opts[:id], opts[:pool])
      return error('container not found') unless ct

      ret = {}

      ct.prlimits.each do |name, limit|
        next if opts[:limits] && !opts[:limits].include?(name)

        ret[name] = limit.export
      end

      ok(ret)
    end
  end
end
