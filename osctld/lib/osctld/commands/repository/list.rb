require 'osctld/commands/base'

module OsCtld
  class Commands::Repository::List < Commands::Base
    handle :repo_list

    def execute
      ret = []

      DB::Repositories.each_by_ids(opts[:names], opts[:pool]) do |repo|
        ret << repo.export.merge!(repo.attrs.export)
      end

      ok(ret)
    end
  end
end
