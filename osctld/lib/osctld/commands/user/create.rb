require 'fileutils'

module OsCtld
  class Commands::User::Create < Commands::Logged
    handle :user_create

    include OsCtl::Lib::Utils::Log
    include OsCtl::Lib::Utils::System

    def find
      pool = DB::Pools.get_or_default(opts[:pool])
      error!('pool not found') unless pool

      rx = /^[a-z_][a-z0-9_-]*$/

      if rx !~ opts[:name]
        error!("invalid name, allowed format: #{rx.source}")

      elsif opts[:ugid] < 1
        error!('invalid ugid: must be greater than 0')

      elsif opts[:offset] < 0
        error!('invalid offset: must be greater or equal to 0')
      end

      # Check for duplicities
      DB::Users.get.each do |u|
        if u.ugid == opts[:ugid]
          error!(
            "ugid #{opts[:ugid]} already taken by user "+
            "#{u.pool.name}:#{u.name}"
          )

        elsif u.offset == opts[:offset]
          error!(
            "offset #{opts[:offset]} already taken by user "+
            "#{u.pool.name}:#{u.name}"
          )
        end
      end

      u = User.new(pool, opts[:name], load: false)
      error!('user already exists') if DB::Users.contains?(u.name, pool)

      u
    end

    def execute(u)
      u.exclusively do
        zfs(:create, nil, u.dataset)

        File.chown(0, opts[:ugid], u.userdir)
        File.chmod(0751, u.userdir)

        Dir.mkdir(u.homedir) unless Dir.exist?(u.homedir)
        File.chown(opts[:ugid], opts[:ugid], u.homedir)
        File.chmod(0751, u.homedir)

        u.configure(opts[:ugid], opts[:offset], opts[:size])
        u.register

        DB::Users.sync do
          DB::Users.add(u)
          call_cmd(Commands::User::SubUGIds)
        end

        UserControl::Supervisor.start_server(u)
      end

      ok
    end
  end
end
