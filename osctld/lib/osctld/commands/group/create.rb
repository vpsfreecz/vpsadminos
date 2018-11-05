require 'osctld/commands/logged'

module OsCtld
  class Commands::Group::Create < Commands::Logged
    handle :group_create

    include OsCtl::Lib::Utils::Log
    include OsCtl::Lib::Utils::System

    def find
      pool = DB::Pools.get_or_default(opts[:pool])
      error!('pool not found') unless pool
      error!('group name has to start with /') unless opts[:name].start_with?('/')

      groups = opts[:name].split('/').drop(1)

      rx = /^[a-z0-9_-]{1,100}$/i

      groups.each do |grp|
        next if rx =~ grp
        error!("invalid name, allowed format: #{rx.source}")
      end

      grp = Group.new(pool, opts[:name], load: false)
      error!('group already exists') if DB::Groups.contains?(grp.name, pool)

      unless opts[:parents]
        begin
          grp.parents

        rescue GroupNotFound => e
          error!(e)
        end
      end

      grp
    end

    def execute(grp)
      manipulate(grp) do
        # Create parent groups
        if opts[:parents]
          t = ''

          opts[:name].split('/')[0..-2].each do |n|
            t = File.join('/', t, n)
            g = DB::Groups.by_path(grp.pool, t)
            next if g

            pgrp = Group.new(grp.pool, t, load: false)
            pgrp.configure

            DB::Groups.add(pgrp)
          end
        end

        # Create last group
        grp.configure
        grp.cgparams.set(grp.cgparams.import(opts[:cgparams] || []))

        DB::Groups.add(grp)
      end

      ok

    rescue CGroupSubsystemNotFound, CGroupParameterNotFound => e
      error(e.message)
    end
  end
end
