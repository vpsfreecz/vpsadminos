module OsCtld
  class Commands::Group::Create < Commands::Logged
    handle :group_create

    include OsCtl::Lib::Utils::Log
    include OsCtl::Lib::Utils::System

    def find
      pool = DB::Pools.get_or_default(opts[:pool])
      error!('pool not found') unless pool

      rx = /^[a-z0-9_-]{1,100}$/i
      error!("invalid name, allowed format: #{rx.source}") if rx !~ opts[:name]

      rx = /^[a-z0-9_\-\.]{1,50}$/i
      opts[:path].split('/').each do |v|
        error!("invalid path component, allowed format: #{rx.source}") if rx !~ v
      end

      grp = Group.new(pool, opts[:name], load: false)
      error!('group already exists') if DB::Groups.contains?(grp.name, pool)
      grp
    end

    def execute(grp)
      params = grp.import_cgparams(opts[:cgparams] || [])

      grp.exclusively do
        grp.configure(opts[:path], params)
        DB::Groups.add(grp)
      end

      ok

    rescue CGroupSubsystemNotFound, CGroupParameterNotFound => e
      error(e.message)
    end
  end
end
