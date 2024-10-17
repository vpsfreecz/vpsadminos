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

    # @return [Container::RunId]
    attr_reader :run_id

    # @return [Container]
    attr_reader :ct

    attr_inclusive_reader :dataset, :distribution, :version, :arch
    attr_synchronized_accessor :cpu_package, :init_pid,
                               :dist_network_configured

    # @param ct [Container]
    def initialize(ct, load_conf: true)
      init_lock
      @ct = ct
      @cpu_package = nil
      @init_pid = nil
      @aborted = false
      @do_reboot = false
      @dist_network_configured = false
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
      id ident pool user group uid_map gid_map lxc_dir log_path config_path
      can_dist_configure_network? log_type
    ].each do |v|
      define_method(v) do |*args, **kwargs|
        ct.send(v, *args, **kwargs)
      end
    end

    # Set custom boot dataset
    def boot_from(dataset, distribution, version, arch, destroy_dataset_on_stop: false)
      exclusively do
        @dataset = dataset
        @distribution = distribution
        @version = version
        @arch = arch
        @destroy_dataset_on_stop = destroy_dataset_on_stop
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

      dataset.mount(recursive: true)
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

    attr_writer :aborted

    def aborted?
      @aborted
    end

    # After the current container run stops, start it again
    def request_reboot
      @do_reboot = true
    end

    def reboot?
      @do_reboot
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
      {
        'id' => run_id.dump,
        'dataset' => dataset.to_s,
        'distribution' => distribution,
        'version' => version,
        'arch' => arch,
        'cpu_package' => cpu_package,
        'destroy_dataset_on_stop' => destroy_dataset_on_stop?
      }
    end

    def load_conf(from_file: true)
      cfg =
        if from_file && File.exist?(file_path)
          OsCtl::Lib::ConfigFile.load_yaml_file(file_path)
        else
          {}
        end

      @run_id =
        if cfg.has_key?('id')
          Container::RunId.load(cfg['id'])
        else
          Container::RunId.new(pool_name: pool.name, container_id: id)
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
      @cpu_package = cfg['cpu_package']
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

      regenerate_file(file_path, 0o400) do |new|
        new.write(OsCtl::Lib::ConfigFile.dump_yaml(dump))
      end
    end

    def destroy
      File.unlink(file_path)
    rescue Errno::ENOENT
      # ignore
    end

    protected

    attr_synchronized_accessor :mounted

    def dir_path
      File.join(ct.pool.ct_dir, ct.id)
    end

    def file_path
      File.join(dir_path, 'config.yml')
    end
  end
end
