require 'yaml'
require 'rubygems'
require 'rubygems/package'
require 'zlib'

module OsCtld
  class Commands::Container::Import < Commands::Logged
    handle :ct_import

    include Utils::Log

    def find
      DB::Pools.get_or_default(opts[:pool]) || error!('pool not found')
    end

    def execute(pool)
      File.open(opts[:file], 'r') do |f|
        import(pool, f)
      end

      ok
    end

    protected
    def import(pool, io)
      tar = Gem::Package::TarReader.new(io)
      data = tar.seek('metadata.yml') do |entry|
        YAML.load(entry.read)
      end

      error!('metadata not found') unless data

      ctid = opts[:as_id] || data['container']

      if DB::Containers.find(ctid, pool)
        error!("container #{pool.name}:#{ctid} already exists")
      end

      if opts[:as_user]
        user = DB::Users.find(opts[:as_user], pool)
        error!('user not found') unless user
        create_user = false

      else
        user, create_user = load_user(
          pool,
          data['user'],
          tar.seek('config/user.yml') { |entry| entry.read }
        )
      end

      if opts[:as_group]
        group = DB::Groups.find(opts[:as_group], pool)
        error('group not found') unless group
        create_group = false

      else
        group, create_group = load_group(
          pool,
          data['group'],
          tar.seek('config/group.yml') { |entry| entry.read }
        )
      end

      if create_user
        call_cmd(
          Commands::User::Create,
          pool: pool.name,
          name: user.name,
          ugid: user.ugid,
          offset: user.offset,
          size: user.size
        )

        user = DB::Users.find(user.name, pool) || error!('expected user')
      end

      if create_group
        call_cmd(
          Commands::Group::Create,
          pool: pool.name,
          name: group.name,
          path: group.path
        )

        group = DB::Groups.find(group.name, pool) || error!('expected group')
      end

      ct = Container.new(
        pool,
        ctid,
        user,
        group,
        load_from: tar.seek('config/container.yml') { |entry| entry.read }
      )
      builder = Container::Builder.new(ct, cmd: self)

      # TODO: check for conflicting configuration
      #   - ip addresses, mac addresses

      unless builder.valid?
        error!("invalid id, allowed format: #{builder.id_chars}")
      end

      builder.create_dataset(offset: true)
      builder.setup_ct_dir
      builder.setup_lxc_home

      load_stream(builder, tar, 'base', true)
      load_stream(builder, tar, 'incremental', false)

      tar.seek('snapshots.yml') do |entry|
        builder.clear_snapshots(YAML.load(entry.read))
      end

      ct.save_config
      builder.setup_lxc_configs
      builder.setup_log_file
      builder.register

      if ct.netifs.any?
        progress('Reconfiguring LXC usernet')
        call_cmd(Commands::User::LxcUsernet)
      end

      ok

    ensure
      tar.close
    end

    def load_user(pool, name, config)
      db = DB::Users.find(name, pool)
      u = User.new(pool, name, config: config)
      return [u, true] unless db

      %i(ugid offset size).each do |param|
        mine = db.send(param)
        other = u.send(param)
        next if mine == other

        error!(
          "user #{pool.name}:#{name} already exists: #{param} mismatch: "+
          "existing #{mine}, trying to import #{other}"
        )
      end

      [db, false]
    end

    def load_group(pool, name, config)
      db = DB::Groups.find(name, pool)
      grp = Group.new(pool, name, config: config)
      return [grp, true] unless db

      %i(path).each do |param|
        mine = db.send(param)
        other = grp.send(param)
        next if mine == other

        error!(
          "group #{pool.name}:#{name} already exists: #{param} mismatch: "+
          "existing #{mine}, trying to import #{other}"
        )
      end

      [db, false]
    end

    def load_stream(builder, tar, name, required)
      found = nil

      stream_names(name).each do |file, compression|
        tf = tar.find { |entry| entry.full_name == file }

        if tf.nil?
          tar.rewind
          next
        end

        found = [tf, compression]
        break
      end

      if found.nil?
        tar.rewind
        fail "unable to import: #{name} not found" if required
        return
      end

      entry, compression = found
      process_stream(builder, entry, compression)
      tar.rewind
    end

    def process_stream(builder, tf, compression)
      builder.from_stream do |recv|
        case compression
        when :gzip
          gz = Zlib::GzipReader.new(tf)
          recv.write(gz.readpartial(16*1024)) until gz.eof?
          gz.close

        when :off
          recv.write(tf.read(16*1024)) until tf.eof?

        else
          fail "unexpected compression type '#{compression}'"
        end
      end
    end

    def stream_names(name)
      base = File.join('rootfs', "#{name}.dat")
      [[base, :off], ["#{base}.gz", :gzip]]
    end
  end
end
