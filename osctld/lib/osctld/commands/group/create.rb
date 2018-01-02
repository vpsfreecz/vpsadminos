module OsCtld
  class Commands::Group::Create < Commands::Base
    handle :group_create

    include Utils::Log
    include Utils::System

    def execute
      pool = DB::Pools.get_or_default(opts[:pool])
      return error('pool not found') unless pool

      grp = Group.new(pool, opts[:name], load: false)
      return error('group already exists') if DB::Groups.contains?(grp.name, pool)

      params = grp.import_cgparams(opts[:cgparams])

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
