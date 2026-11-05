require 'osctld/db/pooled_list'

module OsCtld
  class DB::Repositories < DB::PooledList
    def self.setup(pool)
      repo = Repository.new(pool, 'default')
    rescue Errno::ENOENT
      Commands::Repository::Add.run(
        pool:,
        name: 'default',
        url: Daemon.get.config.default_repository_url
      )
    else
      add(repo)
      repo.start
    end
  end
end
