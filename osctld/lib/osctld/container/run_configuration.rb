require 'libosctl'
require 'osctld/lockable'

module OsCtld
  class Container::RunConfiguration
    include Lockable
    include OsCtl::Lib::Utils::Log
    include OsCtl::Lib::Utils::File

    # @param ct [Container]
    def self.load(ct)
      ctrc = new(ct, load_conf: false)

      return unless ctrc.exist?

      ctrc.load_conf
      ctrc
    end

    def self.load_generation(ct, run_id)
      ctrc = new(ct, load_conf: false, run_id:)
      return unless File.exist?(ctrc.generation_file_path)

      ctrc.load_conf(path: ctrc.generation_file_path)
      ctrc
    end

    # @return [Container::RunId]
    attr_reader :run_id

    # @return [Container]
    attr_reader :ct

    attr_inclusive_reader :dataset, :distribution, :version, :arch, :vendor, :variant
    attr_synchronized_accessor :cpu_package, :init_pid,
                               :dist_network_configured

    # @param ct [Container]
    def initialize(ct, load_conf: true, run_id: nil)
      init_lock
      @ct = ct
      @run_id = run_id
      @cpu_package = nil
      @init_pid = nil
      @aborted = false
      @do_reboot = false
      @exit_promise = Promise.new
      @dist_network_configured = false
      @generation_cgroups = true
      self.load_conf(from_file: load_conf)
    end

    def assets(add)
      add.file(
        file_path,
        desc: 'Container runtime configuration',
        user: 0,
        group: 0,
        mode: 0o400,
        optional: true
      )
    end

    %i[
      id ident pool user group uid_map gid_map map_mode lxc_dir log_path config_path
      can_dist_configure_network? log_type
    ].each do |v|
      define_method(v) do |*args, **kwargs|
        ct.send(v, *args, **kwargs)
      end
    end

    # Set custom boot dataset
    def boot_from(dataset:, distribution:, version:, arch:, vendor:, variant:, destroy_dataset_on_stop: false)
      exclusively do
        @dataset = dataset
        @distribution = distribution
        @version = version
        @arch = arch
        @vendor = vendor
        @variant = variant
        @destroy_dataset_on_stop = destroy_dataset_on_stop
      end
    end

    # Update distribution info
    def set_distribution(distribution:, version:, arch:, vendor:, variant:)
      exclusively do
        @distribution = distribution
        @version = version
        @arch = arch
        @vendor = vendor
        @variant = variant
        save
      end
    end

    def destroy_dataset_on_stop?
      inclusively { @destroy_dataset_on_stop }
    end

    # Countainer dataset mountpoint
    # @return [String]
    def dir
      dataset.mountpoint
    end

    # Container rootfs path
    # @return [String]
    def rootfs
      File.join(dir, 'private')
    rescue SystemCommandFailed
      # Dataset for staged containers does not have to exist yet, relevant
      # primarily for ct show/list
      nil
    end

    # Mount the container's dataset
    # @param force [Boolean] ensure the datasets are mounted even if osctld
    #                        already mounted them
    def mount(force: false)
      return if !force && mounted

      ct.mount(force: force)
      dataset.mount(recursive: true) if ct.dataset.name != dataset.name

      self.mounted = true
    end

    # Check if the container's dataset is mounted
    # @param force [Boolean] check if the dataset is mounted even if osctld
    #                        already mounted it
    def mounted?(force: false)
      if force || mounted.nil?
        self.mounted = dataset.mounted?(recursive: true)
      else
        mounted
      end
    end

    def runtime_rootfs
      pid = init_pid
      raise 'init_pid not set' unless pid

      File.join('/proc', pid.to_s, 'root')
    end

    def generation_cgroups?
      inclusively { @generation_cgroups }
    end

    def cgroup_root
      generation_cgroups? ? ct.run_cgroup_path(run_id) : ct.base_cgroup_path
    end

    def cgroup_path
      generation_cgroups? ? File.join(cgroup_root, 'user-owned') : ct.legacy_cgroup_path
    end

    def wrapper_cgroup_path
      generation_cgroups? ? File.join(cgroup_root, 'wrapper') : ct.legacy_wrapper_cgroup_path
    end

    def lxc_payload_cgroup_path
      File.join(cgroup_path, generation_cgroups? ? 'payload' : "lxc.payload.#{ct.id}")
    end

    def lxc_monitor_cgroup_path
      File.join(cgroup_path, generation_cgroups? ? 'monitor' : "lxc.monitor.#{ct.id}")
    end

    def lxc_pivot_cgroup_path
      File.join(cgroup_path, generation_cgroups? ? 'monitor-pivot' : "lxc.pivot.#{ct.id}")
    end

    def mark_aborted
      exclusively do
        @aborted = true
        save
      end
    end

    def aborted?
      inclusively { @aborted }
    end

    # After the current container run stops, start it again
    def request_reboot
      exclusively do
        @do_reboot = true
        save
      end
    end

    def reboot?
      inclusively { @do_reboot }
    end

    def get_exit_promise
      @exit_promise.add
    end

    def fulfil_exit
      @exit_promise.fulfil
    end

    def dist_configure_network?
      inclusively do
        !dist_network_configured && can_dist_configure_network?
      end
    end

    def exist?
      File.exist?(file_path)
    end

    def dump
      inclusively do
        {
          'id' => run_id.dump,
          'generation_cgroups' => generation_cgroups?,
          'dataset' => dataset.to_s,
          'distribution' => distribution,
          'version' => version,
          'arch' => arch,
          'vendor' => vendor,
          'variant' => variant,
          'cpu_package' => cpu_package,
          'aborted' => aborted?,
          'reboot' => reboot?,
          'destroy_dataset_on_stop' => destroy_dataset_on_stop?
        }
      end
    end

    def load_conf(from_file: true, path: nil)
      source_path = path || file_path
      cfg =
        if from_file && File.exist?(source_path)
          OsCtl::Lib::ConfigFile.load_yaml_file(source_path)
        else
          {}
        end

      @run_id =
        if cfg.has_key?('id')
          Container::RunId.load(cfg['id'])
        elsif @run_id
          @run_id
        else
          Container::RunId.new(pool_name: pool.name, container_id: id)
        end
      @generation_cgroups =
        if from_file && File.exist?(source_path)
          cfg.fetch('generation_cgroups', false)
        else
          true
        end
      @dataset =
        if cfg['dataset']
          OsCtl::Lib::Zfs::Dataset.new(cfg['dataset'], base: cfg['dataset'])
        else
          ct.dataset
        end
      @distribution = cfg['distribution'] || ct.distribution
      @version = cfg['version'] || ct.version
      @arch = cfg['arch'] || ct.arch
      @vendor = cfg['vendor'] || ct.vendor
      @variant = cfg['variant'] || ct.variant
      @cpu_package = cfg['cpu_package']
      @aborted = cfg.fetch('aborted', false)
      @do_reboot = cfg.fetch('reboot', false)
      @destroy_dataset_on_stop =
        if cfg.has_key?('destroy_dataset_on_stop')
          cfg['destroy_dataset_on_stop']
        else
          false
        end
      nil
    end

    def save
      begin
        Dir.mkdir(dir_path)
      rescue Errno::EEXIST
        # ignore
      end

      dumped = OsCtl::Lib::ConfigFile.dump_yaml(dump)

      [generation_file_path, file_path].each do |path|
        regenerate_file(path, 0o400) { |new| new.write(dumped) }
      end
    end

    def destroy
      File.unlink(generation_file_path)
      detach
    rescue Errno::ENOENT
      detach
    end

    # Remove the compatibility pointer only when it still names this run.
    def detach
      return unless current_file_matches?

      File.unlink(file_path)
    rescue Errno::ENOENT
      nil
    end

    def generation_file_path
      File.join(dir_path, "config.#{run_id.key}.yml")
    end

    protected

    attr_synchronized_accessor :mounted

    def dir_path
      File.join(ct.pool.ct_dir, ct.id)
    end

    def file_path
      File.join(dir_path, 'config.yml')
    end

    def current_file_matches?
      cfg = OsCtl::Lib::ConfigFile.load_yaml_file(file_path)
      return false unless cfg['id']

      Container::RunId.load(cfg['id']) == run_id
    rescue Errno::ENOENT, Psych::Exception, KeyError
      false
    end
  end
end
