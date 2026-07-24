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

    attr_inclusive_reader :dataset, :distribution, :version, :arch, :vendor, :variant
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
      @exit_promise = Promise.new
      @runtime_resolution_promise = Promise.new
      @dist_network_configured = false
      @start_pending = false
      @runtime_phase = :inactive
      @exit_cleanup_started = false
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

    attr_writer :aborted

    def aborted?
      @aborted
    end

    # After the current container run stops, start it again
    def request_reboot
      exclusively { @do_reboot = true }
      save
    end

    def reboot?
      inclusively { @do_reboot }
    end

    def get_exit_promise
      @exit_promise.add
    end

    def fulfil_exit
      exclusively { @start_pending = false }
      @runtime_resolution_promise.fulfil
      @exit_promise.fulfil
    end

    def exited?
      @exit_promise.fulfilled?
    end

    def start_pending
      exclusively do
        @start_pending = true
        @runtime_phase = :launching
      end
    end

    def start_pending?
      inclusively { @start_pending }
    end

    def runtime_started
      exclusively { @runtime_phase = :started }
      @runtime_resolution_promise.fulfil
    end

    def runtime_started?
      inclusively { @runtime_phase == :started }
    end

    def runtime_stopping
      exclusively { @runtime_phase = :stopping }
      @runtime_resolution_promise.fulfil
    end

    def runtime_stopping?
      inclusively { @runtime_phase == :stopping }
    end

    def runtime_launching?
      inclusively { @runtime_phase == :launching }
    end

    def runtime_unknown
      exclusively { @runtime_phase = :unknown }
    end

    def runtime_unknown?
      inclusively { @runtime_phase == :unknown }
    end

    def get_runtime_resolution_promise
      @runtime_resolution_promise.add
    end

    # Claim post-stop cleanup
    #
    # Console EOF and an explicit wrapper failure can race each other. Only one
    # of them is allowed to clean up the run.
    def claim_exit_cleanup
      exclusively do
        next false if @exit_cleanup_started

        @exit_cleanup_started = true
        true
      end
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
          'dataset' => dataset.to_s,
          'distribution' => distribution,
          'version' => version,
          'arch' => arch,
          'vendor' => vendor,
          'variant' => variant,
          'cpu_package' => cpu_package,
          'destroy_dataset_on_stop' => destroy_dataset_on_stop?,
          'reboot' => @do_reboot
        }
      end
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
      @vendor = cfg['vendor'] || ct.vendor
      @variant = cfg['variant'] || ct.variant
      @cpu_package = cfg['cpu_package']
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
