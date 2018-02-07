module OsCtld
  class Container::Builder
    include Utils::Log
    include Utils::System
    include Utils::Zfs

    ID_RX = /^[a-z0-9_-]{1,100}$/i

    def self.create(pool, id, user, group, dataset = nil, opts = {})
      new(
        Container.new(
          pool,
          id,
          user,
          group,
          dataset || Container.default_dataset(pool, id),
          load: false
        ),
        opts
      )
    end

    attr_reader :ct, :errors

    # @param ct [Container]
    # @param opts [Hash]
    # @option opts [Command::Base] cmd
    def initialize(ct, opts)
      @ct = ct
      @opts = opts
      @errors = []
    end

    def pool
      ct.pool
    end

    def user
      ct.user
    end

    def group
      ct.group
    end

    def valid?
      if ID_RX !~ ct.id
        errors << "invalid ID, allowed characters: #{ID_RX.source}"
      end

      if !ct.dataset.start_with?("#{ct.pool.name}/")
        errors << "dataset #{ct.dataset} does not belong to pool #{ct.pool.name}"
      end

      errors.empty?
    end

    def exist?
      DB::Containers.contains?(ct.id, ct.pool)
    end

    # @param opts [Hash] options
    # @option opts [Boolean] :offset
    # @option opts [Boolean] :parents
    def create_dataset(opts)
      progress('Creating dataset')

      zfs_opts = []

      if opts[:offset]
        zfs_opts << "-o uidoffset=#{ct.uid_offset} -o gidoffset=#{ct.gid_offset}"
      end

      zfs_opts << '-p' if opts[:parents]

      zfs(:create, zfs_opts.join(' '), ct.dataset)
    end

    def setup_ct_dir
      # Chown to 0:0, zfs will shift it to the offset
      File.chown(0, 0, ct.dir)
      File.chmod(0770, ct.dir)
    end

    def setup_rootfs
      if Dir.exist?(ct.rootfs)
        Dir.chmod(0750, ct.rootfs)
      else
        Dir.mkdir(ct.rootfs, 0750)
      end

      File.chown(0, 0, ct.rootfs)
    end

    # @param template [String] path
    # @param opts [Hash] options
    # @option opts [String] :distribution
    # @option opts [String] :version
    def from_template(template, opts = {})
      progress('Extracting template')
      syscmd("tar -xzf #{template} -C #{ct.rootfs}")

      shift_dataset

      distribution, version, *_ = File.basename(template).split('-')

      configure(
        opts[:distribution] || distribution,
        opts[:version] || version
      )
    end

    def from_stream
      IO.popen("exec zfs recv -F #{ct.dataset}", 'r+') do |io|
        yield(io)
      end
    end

    def shift_dataset
      progress('Unmounting dataset')
      zfs(:unmount, nil, ct.dataset)

      progress('Configuring UID/GID offsets')
      zfs(:set, "uidoffset=#{ct.uid_offset} gidoffset=#{ct.gid_offset}", ct.dataset)

      progress('Remounting dataset')
      zfs(:mount, nil, ct.dataset)
    end

    def configure(distribution, version)
      ct.configure(distribution, version)
    end

    def clear_snapshots(snaps)
      snaps.each do |snap|
        zfs(:destroy, nil, "#{ct.dataset}@#{snap}")
      end
    end

    def setup_lxc_home
      progress('Configuring LXC home')

      unless ct.group.setup_for?(ct.user)
        Dir.mkdir(ct.group.userdir(ct.user), 0751)
        File.chown(0, ct.user.ugid, ct.group.userdir(user))
      end

      Dir.mkdir(ct.lxc_dir, 0750)
      File.chown(0, ct.user.ugid, ct.lxc_dir)

      ct.configure_bashrc
    end

    def setup_lxc_configs
      progress('Generating LXC configuration')
      ct.configure_lxc
    end

    def setup_log_file
      progress('Preparing log file')
      File.open(ct.log_path, 'w').close
      File.chmod(0660, ct.log_path)
      File.chown(0, ct.user.ugid, ct.log_path)
    end

    def register
      progress('Registering container')
      DB::Containers.add(ct)
      Monitor::Master.monitor(ct)
    end

    protected
    def progress(msg)
      return unless @opts[:cmd]
      @opts[:cmd].send(:progress, msg)
    end
  end
end
