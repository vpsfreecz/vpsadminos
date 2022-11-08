require 'forwardable'

module OsCtld
  # Encapsulates one {Lxcfs::Server}, which can be used by one or more containers
  class Lxcfs::Worker
    extend Forwardable
    include Lockable

    # @return [String]
    attr_reader :name

    # @return [Integer]
    attr_reader :max_size

    # @return [Integer, nil]
    attr_reader :cpu_package

    # @return [Integer]
    attr_reader :size

    # @param [Integer]
    # @return [Integer]
    attr_synchronized_accessor :max_size

    # @return [Boolean]
    attr_reader :enabled
    alias_method :enabled?, :enabled

    # @return [Time, nil]
    attr_reader :last_used

    def_delegators :lxcfs, :loadavg, :cfs, :mountpoint, :mount_files

    # @param name [String]
    # @param ctrc [Container::RunConfiguration]
    # @return [Lxcfs::Worker]
    def self.new_for_ctrc(name, ctrc)
      lxcfs = ctrc.ct.lxcfs

      new(
        name,
        cpu_package: ctrc.cpu_package,
        loadavg: lxcfs.loadavg,
        cfs: lxcfs.cfs,
      )
    end

    # @return [Lxcfs::Worker]
    def self.load(cfg)
      new(
        cfg['name'],
        enabled: cfg['enabled'],
        max_size: cfg['max_size'],
        cpu_package: cfg['cpu_package'],
        loadavg: cfg['loadavg'],
        cfs: cfg['cfs'],
      )
    end

    # @param name [String]
    # @param max_size [Integer]
    # @param cpu_package [Integer]
    # @param loadavg [Boolean]
    # @param cfs [Boolean]
    # @param enabled [Boolean]
    def initialize(name, max_size: nil, cpu_package: nil, loadavg: true, cfs: true, enabled: true)
      init_lock
      @name = name
      @max_size = max_size || Daemon.get.config.lxcfs.max_worker_size
      @cpu_package = cpu_package
      @lxcfs = Lxcfs::Server.new(
        name,
        cpuset: cpu_package && CpuScheduler.topology.packages[cpu_package].cpus.keys.join(','),
        loadavg: loadavg,
        cfs: cfs,
      )
      @enabled = enabled
      @size = 0
      @last_used = nil
    end

    def assets(add)
      add.directory(
        lxcfs.mountroot,
        desc: 'LXCFS directory',
        user: 0,
        group: 0,
        mode: 0555,
        optional: true,
      )
      add.directory(
        lxcfs.mountpoint,
        desc: 'LXCFS mountpoint',
        user: 0,
        group: 0,
        mode: 0755,
        optional: true,
      )
    end

    def setup
      lxcfs.reconfigure
    end

    def start
      lxcfs.ensure_start
    end

    def wait
      lxcfs.wait(timeout: 60)
    end

    def destroy
      lxcfs.ensure_destroy
    end

    # @param ctrc [Container::RunConfiguration]
    # @param check_size [Boolean]
    def can_handle_ctrc?(ctrc, check_size: true)
      inclusively do
        enabled \
          && (!check_size || size < max_size) \
          && (ctrc.cpu_package.nil? || ctrc.cpu_package == cpu_package) \
          && ctrc.ct.lxcfs.loadavg == loadavg \
          && ctrc.ct.lxcfs.cfs == cfs
      end
    end

    def enable
      exclusively { @enabled = true }
    end

    def disable
      exclusively { @enabled = false }
    end

    def add_user
      exclusively do
        @size += 1
        @last_used = nil
      end
    end

    def remove_user
      exclusively do
        @size -= 1 if @size > 0
        @last_used = Time.now if @size <= 0
      end
    end

    def has_users?
      exclusively { @size > 0 }
    end

    def unused?
      !has_users?
    end

    def export
      inclusively do
        {
          name: name,
          enabled: enabled,
          size: size,
          max_size: max_size,
          cpu_package: cpu_package,
          loadavg: loadavg,
          cfs: cfs,
          mountpoint: lxcfs.mountpoint,
        }
      end
    end

    def dump
      inclusively do
        {
          'name' => name,
          'enabled' => enabled,
          'max_size' => max_size,
          'cpu_package' => cpu_package,
          'loadavg' => loadavg,
          'cfs' => cfs,
        }
      end
    end

    def adjust_legacy_worker
      File.chmod(0555, lxcfs.mountroot)
      File.chown(0, 0, lxcfs.mountroot)
    end

    protected
    attr_reader :lxcfs
  end
end
