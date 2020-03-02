require 'fileutils'
require 'libosctl'
require 'tempfile'

module OsCtld
  class Container::Builder
    include OsCtl::Lib::Utils::Log
    include OsCtl::Lib::Utils::System
    include Utils::SwitchUser

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
    # @option opts [Command::Base] :cmd
    def initialize(ct, opts = {})
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
    # @option opts [Boolean] :mapping
    # @option opts [Boolean] :parents
    def create_dataset(ds, opts = {})
      zfs_opts = {properties: {
        canmount: 'noauto',
      }}
      zfs_opts[:parents] = true if opts[:parents]
      zfs_opts[:properties].update({
        uidmap: ct.uid_map.map(&:to_s).join(','),
        gidmap: ct.gid_map.map(&:to_s).join(','),
      }) if opts[:mapping]

      ds.create!(zfs_opts)
      ds.mount(recursive: true)
    end

    # @param src [Array<OsCtl::Lib::Zfs::Dataset>]
    # @param dst [Array<OsCtl::Lib::Zfs::Dataset>]
    # @param from [String, nil] base snapshot
    # @return [String] snapshot name
    def copy_datasets(src, dst, from: nil)
      snap = "osctl-copy-#{from ? 'incr' : 'base'}-#{Time.now.to_i}"
      zfs(:snapshot, nil, src.map { |ds| "#{ds}@#{snap}" }.join(' '))

      zipped = src.zip(dst)

      zipped.each do |src_ds, dst_ds|
        progress("Copying dataset #{src_ds.relative_name}")
        syscmd("zfs send -c -p -L #{from ? "-i @#{from}" : ''} #{src_ds}@#{snap} "+
               "| zfs recv -F #{dst_ds}")
      end

      snap
    end

    def setup_ct_dir
      # Chown to 0:0, zfs will shift it using the mapping
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

    # @param image [String] path
    # @param opts [Hash] options
    # @option opts [String] :distribution
    # @option opts [String] :version
    def from_local_archive(image, opts = {})
      progress('Extracting image')
      syscmd("tar -xzf #{image} -C #{ct.rootfs}")

      shift_dataset

      distribution, version, arch = get_distribution_info(image)

      configure(
        opts[:distribution] || distribution,
        opts[:version] || version,
        opts[:arch] || arch
      )
    end

    def from_stream(ds = nil)
      progress('Writing image stream')

      IO.popen("exec zfs recv -F #{ds || ct.dataset}", 'r+') do |io|
        yield(io)
      end

      if $?.exitstatus != 0
        fail "zfs recv failed with exit status #{$?.exitstatus}"
      end
    end

    def shift_dataset
      progress('Configuring UID/GID mapping')

      zfs(:unmount, nil, ct.dataset)
      zfs(
        :set,
        "uidmap=\"#{ct.uid_map.map(&:to_s).join(',')}\" "+
        "gidmap=\"#{ct.gid_map.map(&:to_s).join(',')}\"",
        ct.dataset
      )

      5.times do |i|
        zfs(:mount, nil, ct.dataset)

        f = Tempfile.create(['.ugid-map-test'], ct.dir)
        f.close

        st = File.stat(f.path)
        File.unlink(f.path)

        return if st.uid == ct.root_host_uid && st.gid == ct.root_host_gid

        zfs(:unmount, nil, ct.dataset)
        sleep(1 + i)
      end

      fail 'unable to configure UID/GID mapping'
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
        dir = ct.group.userdir(ct.user)

        FileUtils.mkdir_p(dir, mode: 0751)
        File.chown(0, ct.user.ugid, dir)
      end

      if Dir.exist?(ct.lxc_dir)
        File.chmod(0750, ct.lxc_dir)
      else
        Dir.mkdir(ct.lxc_dir, 0750)
      end
      File.chown(0, ct.user.ugid, ct.lxc_dir)

      ct.configure_bashrc
    end

    def setup_lxc_configs
      progress('Generating LXC configuration')
      ct.lxc_config.configure
    end

    def setup_log_file
      progress('Preparing log file')
      File.open(ct.log_path, 'w').close
      File.chmod(0660, ct.log_path)
      File.chown(0, ct.user.ugid, ct.log_path)
    end

    def setup_user_hook_script_dir
      return if Dir.exist?(ct.user_hook_script_dir)

      progress('Preparing user script hook dir')
      Dir.mkdir(ct.user_hook_script_dir, 0700)
    end

    def register
      DB::Containers.sync do
        if DB::Containers.contains?(ct.id, ct.pool)
          false
        else
          DB::Containers.add(ct)
          true
        end
      end
    end

    def monitor
      Monitor::Master.monitor(ct)
    end

    # Remove a partially created container when the building process failed
    #
    # @param opts [Hash] options
    # @option opts [Boolean] :dataset destroy dataset or not
    def cleanup(opts = {})
      Console.remove(ct)
      zfs(:destroy, '-r', ct.dataset, valid_rcs: [1]) if opts[:dataset]

      syscmd("rm -rf #{ct.lxc_dir} #{ct.user_hook_script_dir}")
      File.unlink(ct.log_path) if File.exist?(ct.log_path)
      File.unlink(ct.config_path) if File.exist?(ct.config_path)

      DB::Containers.remove(ct)

      begin
        if ct.group.has_containers?(ct.user)
          CGroup.rmpath_all(ct.base_cgroup_path)

        else
          CGroup.rmpath_all(ct.group.full_cgroup_path(ct.user))
        end
      rescue SystemCallError
        # If some of the cgroups are busy, just leave them be
      end

      bashrc = File.join(ct.lxc_dir, '.bashrc')
      File.unlink(bashrc) if File.exist?(bashrc)

      grp_dir = ct.group.userdir(ct.user)

      if !ct.group.has_containers?(ct.user) && Dir.exist?(grp_dir)
        Dir.rmdir(grp_dir)
      end
    end

    def get_distribution_info(image)
      distribution, version, arch, *_ = File.basename(image).split('-')
      [distribution, version, arch]
    end

    protected
    def progress(msg)
      return unless @opts[:cmd]
      @opts[:cmd].send(:progress, msg)
    end
  end
end
