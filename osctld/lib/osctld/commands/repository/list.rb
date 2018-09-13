require 'osctld/commands/base'

module OsCtld
  class Commands::Repository::List < Commands::Base
    handle :repo_list

    def execute
      ret = []

      DB::Repositories.get.each do |repo|
        next if opts[:pool] && !opts[:pool].include?(repo.pool.name)
        next if opts[:names] && !opts[:names].include?(repo.name)

        ret << {
          pool: repo.pool.name,
          name: repo.name,
          url: repo.url,
          enabled: repo.enabled?,
        }.merge!(repo.attrs.export)
      end

      ok(ret)
    end
  end
end
