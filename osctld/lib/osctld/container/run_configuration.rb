require 'libosctl'
require 'osctld/lockable'
require 'osctld/container/nfs_cancellation'

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
    include OsCtl::Lib::Utils::System

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

    attr_reader :nfs_cancellation

    attr_inclusive_reader :dataset, :distribution, :version, :arch, :vendor, :variant
    attr_synchronized_accessor :cpu_package, :dist_network_configured
    attr_inclusive_reader :init_pid

    # @param ct [Container]
    def initialize(ct, load_conf: true)
      init_lock
      @ct = ct
      @cpu_package = nil
      @init_pid = nil
      @nfs_cancellation = Container::NfsCancellation.new(ct)
      @init_identity = nil
      @init_lease_mutex = Mutex.new
      @init_lease_cond = ConditionVariable.new
      @init_lease_count = 0
      @retiring = false
      @destroyed = false
      @aborted = false
      @do_reboot = false
      @exit_promise = Promise.new
      @exit_handling_started = false
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
      install_init_identity { ProcessIdentity.new(pid, namespaces: [:mnt], root: true) }
    end

    # Import retains its authenticated descriptors; never reopen the numeric PID.
    # The caller keeps its identity, while this run owns an independent copy.
    def retain_init_identity(identity)
      install_init_identity { identity.duplicate }
    end

    # Called only for an unpublished, running impermanent CT during pool import.
    # Prove the saved base root, or the temporary root and its existing GC owner.
    # Preparation may use the selected root, but persistence waits for all final
    # checks. There are no monitor callbacks or collector worker during this call.
    def recover_impermanent_root!(pid, publish:)
      original_dataset = @dataset
      original_cleanup = @destroy_dataset_on_stop
      identity = nil
      installed = false
      completed = false

      validate_saved_run!
      base_selection = dataset.name == ct.dataset.name
      if base_selection && destroy_dataset_on_stop?
        raise ConfigError, 'stale base selection has contradictory cleanup state'
      end

      ownership = pool.garbage_collector.container_run_dataset_ownership(allow_missing: base_selection)
      records = ownership.first
      ordinary_base = base_selection && records.none? { |row| row['run_id'] == run_id.dump }
      if ordinary_base
        conflicting = records.any? do |row|
          other = row['dataset']
          other.is_a?(String) &&
            (other == dataset.name || other.start_with?("#{dataset.name}/") || dataset.name.start_with?("#{other}/"))
        end
        raise ConfigError, 'base root has conflicting GC ownership' if conflicting

        candidate = dataset.name
      else
        candidate = impermanent_root_owner(records)
      end
      repair = base_selection && !ordinary_base

      unless ordinary_base || repair || (dataset.name == candidate && destroy_dataset_on_stop?)
        raise ConfigError, 'saved temporary root contradicts GC ownership'
      end

      identity = ProcessIdentity.new(pid, namespaces: [:mnt], root: true)
      identity.authenticate!(cgroup_path: ct.payload_cgroup_path)
      birth = init_birth(identity)
      mount = init_root_mount(identity, candidate)
      zfs_identity = root_dataset_identity(candidate, identity, temporary: !ordinary_base)

      unless ordinary_base
        @dataset = OsCtl::Lib::Zfs::Dataset.new(candidate, base: candidate)
        @destroy_dataset_on_stop = true
      end
      yield if block_given?

      # Installation can wait for leases. Do it before the last authentication,
      # while the standalone identity is still held; never lease this run here.
      retain_init_identity(identity)
      installed = true
      unless root_dataset_identity(candidate, identity, temporary: !ordinary_base) == zfs_identity &&
             init_root_mount(identity, candidate) == mount && init_birth(identity) == birth
        raise ConfigError, 'live root changed during import'
      end
      unless runtime_config_input == @loaded_input &&
             pool.garbage_collector.container_run_dataset_ownership(allow_missing: ordinary_base) == ownership
        raise ConfigError, 'saved run or GC ownership changed during import'
      end

      identity.authenticate!(cgroup_path: ct.payload_cgroup_path)
      if repair
        regenerate_file(file_path, 0o400) do |new|
          new.write(OsCtl::Lib::ConfigFile.dump_yaml(@loaded_config.merge(
                                                       'dataset' => candidate,
                                                       'destroy_dataset_on_stop' => true
                                                     )))
        end
      end
      publish.call
      completed = true
      nil
    rescue SystemCallError, IOError, ArgumentError, KeyError, Psych::Exception, SystemCommandFailed => e
      raise ConfigError.new('unable to authenticate impermanent live root', e)
    ensure
      unless completed
        @dataset = original_dataset
        @destroy_dataset_on_stop = original_cleanup
        close_init_identity if installed
      end
      identity&.close
    end

    # A transient LXC run can stop without retiring its runtime configuration.
    # Discard only a proven-dead pinned identity; a stopped monitor alone is
    # insufficient proof, since an orphaned init may still be alive. Existing
    # leases own duplicate descriptors and remain valid until their release.
    def clear_dead_init_identity
      identity = nil
      @init_lease_mutex.synchronize do
        exclusively do
          return false if @init_identity.nil? || @init_identity.alive?

          identity = @init_identity
          @init_identity = nil
          @init_pid = nil
        end
      end
      identity.close
      true
    end

    # Acquire a descriptor-authenticated identity lease. Ordinary run locks are
    # held only while the descriptors are duplicated. Retirement and identity
    # replacement then coordinate through the lease condition instead of
    # holding shared state locks across external work.
    def acquire_init_lease
      identity = nil
      leased = false

      @init_lease_mutex.synchronize do
        raise LifecycleError, 'container run is retiring' if @retiring || @destroyed

        identity = inclusively do
          @init_identity&.duplicate
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

    def claim_exit_handling
      exclusively do
        next false if @exit_handling_started

        @exit_handling_started = true
      end
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
          @loaded_input = runtime_config_input
          @loaded_config = OsCtl::Lib::ConfigFile.load_yaml(@loaded_input.last)
          unless @loaded_config.is_a?(Hash)
            raise ConfigError, 'runtime configuration must be a mapping'
          end
          if @loaded_config.has_key?('id') && !@loaded_config['id'].is_a?(Hash)
            raise ConfigError, 'runtime configuration has an invalid run ID'
          end

          @loaded_config
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
    rescue Psych::Exception, KeyError, ArgumentError, TypeError => e
      raise ConfigError.new('invalid runtime configuration', e)
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
      begin
        nfs_cancellation.close
      ensure
        close_init_identity
      end
    end

    protected

    def runtime_config_input
      File.open(file_path, File::RDONLY | File::NOFOLLOW) do |f|
        before = f.stat
        bytes = f.read
        after = f.stat
        previous = [before.dev, before.ino, before.size, before.mtime, before.ctime]
        current = [after.dev, after.ino, after.size, after.mtime, after.ctime]
        unless before.file? && previous == current
          raise ConfigError, 'runtime configuration changed during import'
        end

        [current, bytes]
      end
    end

    def validate_saved_run!
      cfg = @loaded_config
      required = %w[id dataset distribution version arch vendor variant destroy_dataset_on_stop]
      unless cfg.is_a?(Hash) && required.all? { |key| cfg.has_key?(key) } &&
             cfg['id'].is_a?(Hash) && cfg['id']['pool_name'] == pool.name &&
             cfg['id']['container_id'] == id && cfg['id']['timestamp'].is_a?(Numeric) &&
             cfg['id']['timestamp'].finite? && cfg['id']['timestamp'] > 0 &&
             cfg['id'] == run_id.dump && cfg['dataset'] == dataset.name &&
             [true, false].include?(cfg['destroy_dataset_on_stop']) &&
             %w[distribution version arch vendor variant].all? { |key| cfg[key].is_a?(String) && !cfg[key].empty? }
        raise ConfigError, 'running impermanent container requires complete saved run metadata'
      end
    end

    def impermanent_root_owner(records)
      matching = records.select { |row| row['run_id'] == run_id.dump }
      unless matching.one?
        raise ConfigError, 'temporary root requires one existing GC owner for the saved run'
      end

      candidate = matching.first['dataset']
      suffix = dataset.name == ct.dataset.name ? 'impermanence' : '(?:impermanence|boot)'
      pattern = /\A#{Regexp.escape(ct.dataset.name)}\.#{suffix}-[0-9a-f]{6}\z/
      unless candidate.is_a?(String) && candidate.match?(pattern)
        raise ConfigError, 'temporary root has conflicting or foreign GC ownership'
      end

      overlapping = records.count do |row|
        other = row['dataset']
        other.is_a?(String) &&
          (other == candidate || other.start_with?("#{candidate}/") || candidate.start_with?("#{other}/"))
      end
      unless overlapping == 1
        raise ConfigError, 'temporary root has conflicting or foreign GC ownership'
      end

      candidate
    end

    def init_birth(identity)
      namespace_pids = identity.read_proc_file('status').lines.grep(/\ANSpid:\s/)
      pids = namespace_pids.one? ? namespace_pids.first.split.drop(1) : []
      unless pids.length >= 2 && pids.first == identity.pid.to_s && pids.last == '1'
        raise ConfigError, 'live process is not the container namespace init'
      end

      stat = identity.read_proc_file('stat')
      unless stat.start_with?("#{identity.pid} (") && stat.include?(')')
        raise ConfigError, 'invalid init process birth identity'
      end

      birth = stat.rpartition(')').last.split.fetch(19)
      raise ConfigError, 'invalid init process birth identity' unless birth.match?(/\A[0-9]+\z/) && birth.to_i > 0

      birth
    end

    def root_mount_entries(bytes)
      bytes.lines.map do |line|
        fields, filesystem = line.strip.split(' - ', 2)
        left = fields&.split
        right = filesystem&.split
        raise ConfigError, 'malformed mount identity' unless left && left.length >= 6 && right && right.length >= 3

        [left[2], left[3], left[4], right[0], right[1]].map do |value|
          value.gsub(/\\([0-7]{3})/) { Regexp.last_match(1).to_i(8).chr }
        end
      end
    end

    def init_root_mount(identity, candidate)
      roots = root_mount_entries(identity.read_proc_file('mountinfo')).select { |row| row[2] == '/' }
      stat = identity.root_dir.stat
      expected = ["#{stat.dev_major}:#{stat.dev_minor}", '/private', '/', 'zfs', candidate]
      raise ConfigError, 'init root is not the selected dataset private root' unless roots == [expected]

      roots.first
    end

    def root_dataset_identity(candidate, identity, temporary:)
      output = syscmd_argv([
                             'zfs', 'list', '-H', '-p', '-t', 'filesystem',
                             '-o', 'name,guid,mountpoint,mounted,origin', candidate
                           ]).output.lines.map { |line| line.chomp.split("\t") }
      unless output.one? && output.first.length == 5 && output.first[0] == candidate &&
             output.first[1].match?(/\A[1-9][0-9]*\z/) && output.first[2].start_with?('/') &&
             output.first[3] == 'yes' && (!temporary || output.first[4] == '-')
        raise ConfigError, 'root ZFS identity is missing or unsupported'
      end

      properties = output.first
      File.open(properties[2], File::RDONLY | File::NOFOLLOW) do |directory|
        private_root = OsCtl::Lib::Sys.new.open_beneath(directory, 'private')
        begin
          host = private_root.stat
          guest = identity.root_dir.stat
          unless directory.stat.directory? && host.directory? && host.dev == guest.dev && host.ino == guest.ino
            raise ConfigError, 'selected private root differs from the held init root'
          end

          mounts = root_mount_entries(File.read('/proc/self/mountinfo')).select { |row| row[2] == properties[2] }
          expected = ["#{host.dev_major}:#{host.dev_minor}", '/', properties[2], 'zfs', candidate]
          raise ConfigError, 'selected dataset mount identity is ambiguous' unless mounts == [expected]

          [properties, host.dev, host.ino, directory.stat.dev, directory.stat.ino]
        ensure
          private_root.close
        end
      end
    end

    def install_init_identity
      identity = nil
      old_identity = nil

      @init_lease_mutex.synchronize do
        raise LifecycleError, 'container run is retiring' if @retiring || @destroyed
      end

      identity = yield

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

      @init_pid
    ensure
      old_identity&.close
      identity&.close
    end

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
