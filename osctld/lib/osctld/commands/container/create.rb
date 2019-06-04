require 'osctld/commands/logged'

module OsCtld
  class Commands::Container::Create < Commands::Logged
    handle :ct_create

    include OsCtl::Lib::Utils::Log
    include OsCtl::Lib::Utils::System
    include Utils::Container

    def find
      pool = DB::Pools.get_or_default(opts[:pool])
      error!('pool not found') unless pool

      pool
    end

    def execute(pool)
      if DB::Containers.find(opts[:id], pool)
        error!("container #{pool.name}:#{opts[:id]} already exists")
      end

      if opts[:user]
        user = DB::Users.find(opts[:user], pool)
        error!('user not found') unless user
      end

      if opts[:group]
        group = DB::Groups.find(opts[:group], pool)
        error!('group not found') unless group
      end

      if !opts[:image].is_a?(::Hash)
        error!('invalid input')

      elsif !opts[:image][:distribution]
        error!('provide distribution')

      elsif !opts[:image][:version]
        error!('provide distribution version')

      elsif !opts[:image][:arch]
        error!('provide architecture')
      end

      progress('Fetching image')
      tpl_path = get_image_path(get_repositories(pool), opts[:image])
      error!('image not found in searched repositories') if tpl_path.nil?

      call_cmd!(
        Commands::Container::Import,
        pool: pool.name,
        as_id: opts[:id],
        as_user: opts[:user],
        as_group: opts[:group],
        dataset: opts[:dataset],
        file: tpl_path,
      )
    end
  end
end
