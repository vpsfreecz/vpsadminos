require 'libosctl'
require 'osctld/lockable'

module OsCtld
  class Container::RunConfiguration
    class LifecycleError < StandardError; end

    # A short-lived reference to one descriptor-authenticated init identity.
    # Retirement rejects new leases and waits for existing leases to close, so
    # callers can release ordinary container/run locks before blocking work.
    class InitLease
      attr_reader :identity

      def initialize(run_conf, identity)
        @run_conf = run_conf
        @identity = identity
        @mutex = Mutex.new
        @closed = false
      end

      def close
        release = @mutex.synchronize do
          next false if @closed

          @closed = true
          true
        end
        return unless release

        begin
          @identity.close
        ensure
          @run_conf.send(:release_init_lease)
          @identity = nil
        end
      end
    end

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
    attr_synchronized_accessor :cpu_package, :dist_network_configured
    attr_inclusive_reader :init_pid

    # @param ct [Container]
    def initialize(ct, load_conf: true)
      init_lock
      @ct = ct
      @cpu_package = nil
      @init_pid = nil
      @init_identity = nil
      @init_lease_mutex = Mutex.new
      @init_lease_cond = ConditionVariable.new
      @init_lease_count = 0
      @retiring = false
      @destroyed = false
      @aborted = false
      @do_reboot = false
      @exit_promise = Promise.new
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

    def init_pid=(pid)
      identity = nil
      old_identity = nil

      @init_lease_mutex.synchronize do
        raise LifecycleError, 'container run is retiring' if @retiring || @destroyed
      end

      identity = ProcessIdentity.new(pid)

      @init_lease_mutex.synchronize do
        @init_lease_cond.wait(@init_lease_mutex) while @init_lease_count > 0 && !@retiring

        raise LifecycleError, 'container run is retiring' if @retiring || @destroyed

        exclusively do
          old_identity = @init_identity
          @init_identity = identity
          @init_pid = identity.pid
          identity = nil
        end
      end

      old_identity&.close
      @init_pid
    ensure
      identity&.close
    end

    # Acquire a descriptor-authenticated identity lease. Ordinary run locks are
    # held only while the descriptors are duplicated. Retirement and identity
    # replacement then coordinate through the lease condition instead of
    # holding shared state locks across external work.
    def acquire_init_lease(namespaces: [], root: false)
      identity = nil
      leased = false

      @init_lease_mutex.synchronize do
        raise LifecycleError, 'container run is retiring' if @retiring || @destroyed

        identity = inclusively do
          @init_identity&.duplicate(namespaces:, root:)
        end
        return unless identity

        @init_lease_count += 1
        leased = true
      end

      InitLease.new(self, identity)
    rescue StandardError
      identity&.close
      release_init_lease if leased
      raise
    end

    # Prevent new init leases without waiting for current holders. This is
    # called while the container still points at this run, making detachment
    # atomic with respect to lease acquisition.
    def begin_retirement
      @init_lease_mutex.synchronize do
        return false if @retiring

        @retiring = true
        @init_lease_cond.broadcast
        true
      end
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
          'dataset' => dataset.to_s,
          'distribution' => distribution,
          'version' => version,
          'arch' => arch,
          'vendor' => vendor,
          'variant' => variant,
          'cpu_package' => cpu_package,
          'destroy_dataset_on_stop' => destroy_dataset_on_stop?
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
      begin_retirement
      wait_for_init_leases
      File.unlink(file_path)
    rescue Errno::ENOENT
      # ignore
    ensure
      close_init_identity
    end

    protected

    def wait_for_init_leases
      @init_lease_mutex.synchronize do
        @init_lease_cond.wait(@init_lease_mutex) while @init_lease_count > 0
        @destroyed = true
      end
    end

    def release_init_lease
      @init_lease_mutex.synchronize do
        raise LifecycleError, 'init identity lease underflow' unless @init_lease_count > 0

        @init_lease_count -= 1
        @init_lease_cond.broadcast if @init_lease_count == 0
      end
    end

    def close_init_identity
      identity = nil

      exclusively do
        identity = @init_identity
        @init_identity = nil
        @init_pid = nil
      end

      identity&.close
    end

    attr_synchronized_accessor :mounted

    def dir_path
      File.join(ct.pool.ct_dir, ct.id)
    end

    def file_path
      File.join(dir_path, 'config.yml')
    end
  end
end
