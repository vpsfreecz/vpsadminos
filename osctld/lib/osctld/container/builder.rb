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
      ct = Container.new(
        pool,
        id,
        user,
        group,
        dataset || Container.default_dataset(pool, id),
        load: false,
      )

      ctrc = Container::RunConfiguration.new(ct)

      new(ctrc, opts)
    end

    attr_reader :ctrc, :errors

    # @param ctrc [Container::RunConfiguration]
    # @param opts [Hash]
    # @option opts [Command::Base] :cmd
    def initialize(ctrc, opts = {})
      @ctrc = ctrc
      @opts = opts
      @errors = []
      @ds_builder = Container::DatasetBuilder.new(cmd: opts[:cmd])
    end

    def pool
      ctrc.pool
    end

    def user
      ctrc.user
    end

    def group
      ctrc.group
    end

    def valid?
      if ID_RX !~ ctrc.id
        errors << "invalid ID, allowed characters: #{ID_RX.source}"
      end

      if !ctrc.dataset.on_pool?(ctrc.pool.name)
        errors << "dataset #{ctrc.dataset} does not belong to pool #{ctrc.pool.name}"
      end

      errors.empty?
    end

    def exist?
      DB::Containers.contains?(ctrc.id, ctrc.pool)
    end

    def create_root_dataset(opts = {})
      progress('Creating root dataset')
      create_dataset(ctrc.dataset, opts)
    end

    # @param ds [OsCtl::Lib::Zfs::Dataset]
    # @param opts [Hash] options
    # @option opts [Boolean] :mapping
    # @option opts [Boolean] :parents
    def create_dataset(ds, opts = {})
      ds_builder.create_dataset(
        ds,
        parents: opts[:parents],
        uid_map: opts[:mapping] ? ctrc.uid_map : nil,
        gid_map: opts[:mapping] ? ctrc.gid_map : nil,
      )
    end

    # @param src [Array<OsCtl::Lib::Zfs::Dataset>]
    # @param dst [Array<OsCtl::Lib::Zfs::Dataset>]
    # @param from [String, nil] base snapshot
    # @return [String] snapshot name
    def copy_datasets(src, dst, from: nil)
      ds_builder.copy_datasets(src, dst, from: from)
    end

    # @param image [String] path
    # @param opts [Hash] options
    # @option opts [String] :distribution
    # @option opts [String] :version
    def from_local_archive(image, opts = {})
      ds_builder.from_local_archive(image, ctrc.rootfs, opts)

      distribution, version, arch = get_distribution_info(image)

      configure(
        opts[:distribution] || distribution,
        opts[:version] || version,
        opts[:arch] || arch
      )
    end

    def from_stream(ds = nil, &block)
      ds_builder.from_stream(ds || ctrc.dataset, &block)
    end

    def shift_dataset
      ds_builder.shift_dataset(
        ctrc.dataset,
        uid_map: ctrc.uid_map,
        gid_map: ctrc.gid_map,
      )
    end

    def setup_ct_dir
      # Chown to 0:0, zfs will shift it using the mapping
      File.chown(0, 0, ctrc.dir)
      File.chmod(0770, ctrc.dir)
    end

    def setup_rootfs
      if Dir.exist?(ctrc.rootfs)
        File.chmod(0755, ctrc.rootfs)
      else
        Dir.mkdir(ctrc.rootfs, 0755)
      end

      File.chown(0, 0, ctrc.rootfs)
    end

    def configure(distribution, version, arch)
      ctrc.ct.configure(distribution, version, arch)
    end

    def clear_snapshots(snaps)
      snaps.each do |snap|
        zfs(:destroy, nil, "#{ctrc.dataset}@#{snap}")
      end
    end

    def setup_lxc_home
      progress('Configuring LXC home')

      unless ctrc.group.setup_for?(ctrc.user)
        dir = ctrc.group.userdir(ctrc.user)

        FileUtils.mkdir_p(dir, mode: 0751)
        File.chown(0, ctrc.user.ugid, dir)
      end

      if Dir.exist?(ctrc.lxc_dir)
        File.chmod(0750, ctrc.lxc_dir)
      else
        Dir.mkdir(ctrc.lxc_dir, 0750)
      end
      File.chown(0, ctrc.user.ugid, ctrc.lxc_dir)

      ctrc.ct.configure_bashrc
    end

    def setup_lxc_configs
      progress('Generating LXC configuration')
      ctrc.ct.lxc_config.configure
    end

    def setup_log_file
      progress('Preparing log file')
      File.open(ctrc.log_path, 'w').close
      File.chmod(0660, ctrc.log_path)
      File.chown(0, ctrc.user.ugid, ctrc.log_path)
    end

    def setup_user_hook_script_dir
      return if Dir.exist?(ctrc.ct.user_hook_script_dir)

      progress('Preparing user script hook dir')
      Dir.mkdir(ctrc.ct.user_hook_script_dir, 0700)
    end

    def register
      DB::Containers.sync do
        if DB::Containers.contains?(ctrc.id, ctrc.pool)
          false
        else
          DB::Containers.add(ctrc.ct)
          true
        end
      end
    end

    def monitor
      Monitor::Master.monitor(ctrc.ct)
    end

    # Remove a partially created container when the building process failed
    #
    # @param opts [Hash] options
    # @option opts [Boolean] :dataset destroy dataset or not
    def cleanup(opts = {})
      Console.remove(ct)
      zfs(:destroy, '-r', ctrc.dataset, valid_rcs: [1]) if opts[:dataset]

      syscmd("rm -rf #{ctrc.lxc_dir} #{ctrc.ct.user_hook_script_dir}")
      File.unlink(ctrc.log_path) if File.exist?(ctrc.log_path)
      File.unlink(ctrc.config_path) if File.exist?(ctrc.config_path)

      DB::Containers.remove(ct)

      begin
        if ctrc.group.has_containers?(ctrc.user)
          CGroup.rmpath_all(ctrc.ct.base_cgroup_path)

        else
          CGroup.rmpath_all(ctrc.ct.group.full_cgroup_path(ctrc.user))
        end
      rescue SystemCallError
        # If some of the cgroups are busy, just leave them be
      end

      bashrc = File.join(ctrc.lxc_dir, '.bashrc')
      File.unlink(bashrc) if File.exist?(bashrc)

      grp_dir = ctrc.group.userdir(ctrc.user)

      if !ctrc.group.has_containers?(ctrc.user) && Dir.exist?(grp_dir)
        Dir.rmdir(grp_dir)
      end
    end

    def get_distribution_info(image)
      distribution, version, arch, *_ = File.basename(image).split('-')
      [distribution, version, arch]
    end

    protected
    attr_reader :ds_builder

    def progress(msg)
      return unless @opts[:cmd]
      @opts[:cmd].send(:progress, msg)
    end
  end
end
