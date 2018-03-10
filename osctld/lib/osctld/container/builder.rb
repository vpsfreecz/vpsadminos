module OsCtld
  class Container::Builder
    include OsCtl::Lib::Utils::Log
    include OsCtl::Lib::Utils::System
    include Utils::SwitchUser
    include Utils::Repository

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

      if !ct.dataset.on_pool?(ct.pool.name)
        errors << "dataset #{ct.dataset} does not belong to pool #{ct.pool.name}"
      end

      errors.empty?
    end

    def exist?
      DB::Containers.contains?(ct.id, ct.pool)
    end

    def create_root_dataset(opts = {})
      progress('Creating root dataset')
      create_dataset(ct.dataset, opts)
    end

    # @param ds [OsCtl::Lib::Zfs::Dataset]
    # @param opts [Hash] options
    # @option opts [Boolean] :offset
    # @option opts [Boolean] :parents
    def create_dataset(ds, opts = {})
      zfs_opts = {}
      zfs_opts[:parents] = true if opts[:parents]
      zfs_opts[:properties] = {
        uidoffset: ct.uid_offset,
        gidoffset: ct.gid_offset,
      } if opts[:offset]

      ds.create!(zfs_opts)
    end

    def setup_ct_dir
      # Chown to 0:0, zfs will shift it to the offset
      File.chown(0, 0, ct.dir)
      File.chmod(0770, ct.dir)
    end

    def setup_rootfs
      if Dir.exist?(ct.rootfs)
        File.chmod(0755, ct.rootfs)
      else
        Dir.mkdir(ct.rootfs, 0755)
      end

      File.chown(0, 0, ct.rootfs)
    end

    # @param repo [Repository]
    # @param tpl [Hash]
    # @option tpl [String] :vendor
    # @option tpl [String] :variant
    # @option tpl [String] :arch
    # @option tpl [String] :distribution
    # @option tpl [String] :version
    def from_repo_template(repo, tpl)
      progress('Fetching and applying template')

      created = %i(from_repo_stream from_repo_archive).detect do |m|
        method(m).call(repo, tpl)
      end

      unless created
        raise TemplateNotFound, 'no supported template format available'
      end

      shift_dataset

      configure(
        tpl[:distribution],
        tpl[:version],
        tpl[:arch]
      )
    end

    def from_repo_archive(repo, tpl)
      r, w = IO.pipe
      tar = Process.spawn('tar', '-xz', '-C', ct.rootfs, in: r)
      r.close

      get = osctl_repo_get(repo, tpl, 'tar', w)

      _, tar_status = Process.wait2(tar)

      if get === false
        # format not found
        return false

      elsif tar_status.exitstatus != 0
        fail "unable to untar the template, exited with #{tar_status.exitstatus}"
      end

      true
    end

    def from_repo_stream(repo, tpl)
      get = nil
      wait_threads = nil

      Open3.pipeline_w(
        ['gunzip'],
        ['zfs', 'recv', '-F', ct.dataset.name]
      ) do |input, ts|
        get = osctl_repo_get(repo, tpl, 'zfs', input)
        wait_threads = ts
      end

      # format not found
      return false if get === false

      wait_threads.map(&:value).each do |st|
        next if st.exitstatus == 0
        fail "unable to recv the template, process exited with #{st.exitstatus}"
      end

      true
    end

    # @param template [String] path
    # @param opts [Hash] options
    # @option opts [String] :distribution
    # @option opts [String] :version
    def from_local_archive(template, opts = {})
      progress('Extracting template')
      syscmd("tar -xzf #{template} -C #{ct.rootfs}")

      shift_dataset

      distribution, version, arch = get_distribution_info(template)

      configure(
        opts[:distribution] || distribution,
        opts[:version] || version,
        opts[:arch] || arch
      )
    end

    def from_stream(ds = nil)
      progress('Writing template stream')

      IO.popen("exec zfs recv -F #{ds || ct.dataset}", 'r+') do |io|
        yield(io)
      end

      if $?.exitstatus != 0
        fail "zfs recv failed with exit status #{$?.exitstatus}"
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

    def configure(distribution, version, arch)
      ct.configure(distribution, version, arch)
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

    def get_distribution_info(template)
      distribution, version, arch, *_ = File.basename(template).split('-')
      [distribution, version, arch]
    end

    protected
    def progress(msg)
      return unless @opts[:cmd]
      @opts[:cmd].send(:progress, msg)
    end
  end
end
