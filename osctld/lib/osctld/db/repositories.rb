require 'osctld/db/pooled_list'

module OsCtld
  class DB::Repositories < DB::PooledList
    def self.setup(pool)
      repo = Repository.new(pool, 'default')
      add(repo)

    rescue Errno::ENOENT
      #Commands::Repository::Add.run!(
      #  pool: pool,
      #  name: 'default',
      #  url: 'http://192.168.122.75/repo/'
      #)

      Commands::Repository::Add.run(
        pool: pool,
        name: 'default',
        url: 'https://templates.vpsadminos.org'
      )
    end
  end
end
