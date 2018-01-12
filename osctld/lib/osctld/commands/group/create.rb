module OsCtld
  class Commands::Group::Create < Commands::Base
    handle :group_create

    include Utils::Log
    include Utils::System

    def execute
      pool = DB::Pools.get_or_default(opts[:pool])
      return error('pool not found') unless pool

      rx = /^[a-z0-9_-]{1,100}$/i
      return error("invalid name, allowed format: #{rx.source}") if rx !~ opts[:name]

      rx = /^[a-z0-9_\-\.]{1,50}$/i
      opts[:path].split('/').each do |v|
        return error("invalid path component, allowed format: #{rx.source}") if rx !~ v
      end

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
