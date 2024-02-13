require 'libosctl'
require 'securerandom'

module OsCtld
  class TrashBin
    # @param pool [Pool]
    # @param dataset [OsCtl::Lib::Zfs::Dataset]
    def self.add_dataset(pool, dataset)
      pool.trash_bin.add_dataset(dataset)
    end

    include OsCtl::Lib::Utils::Log
    include OsCtl::Lib::Utils::System

    # @return [Pool]
    attr_reader :pool

    # @param pool [Pool]
    def initialize(pool)
      @pool = pool
      @trash_dataset = OsCtl::Lib::Zfs::Dataset.new(pool.trash_bin_ds)
      @queue = OsCtl::Lib::Queue.new
      @stop = false
    end

    def start
      @stop = false
      @thread = Thread.new { run_gc }
    end

    def stop
      return unless @thread

      @stop = true
      @queue << :stop
      @thread.join
      @thread = nil
    end

    def prune
      @queue << :prune
    end

    # @param dataset [OsCtl::Lib::Zfs::Dataset]
    def add_dataset(dataset)
      # Set canmount on the dataset and umount it with and all its descendants
      dataset.list.reverse_each do |ds|
        zfs(:set, 'canmount=noauto', ds.name)

        # We ignore errors, because the dataset may belong to
        # a hung container, etc.
        begin
          zfs(:unmount, nil, ds.name)
        rescue SystemCommandFailed => e
          unless e.output.include?('not currently mounted')
            log(:warn, "Unable to unmount #{ds}: #{e.message}")
          end
        end
      end

      # Move the dataset to trash
      trash_ds, t = trash_path(dataset)
      zfs(:rename, nil, "#{dataset} #{trash_ds}")

      # Set metadata properties
      meta = {
        original_name: dataset.name,
        trashed_at: t.to_i
      }

      zfs(
        :set,
        meta.map { |k, v| "org.vpsadminos.osctl.trash-bin:#{k}=#{v}" }.join(' '),
        trash_ds
      )
    end

    def log_type
      "#{pool.name}:trash"
    end

    protected

    def run_gc
      loop do
        v = @queue.pop(timeout: Daemon.get.config.trash_bin.prune_interval)
        return if v == :stop

        log(:info, 'Pruning')
        prune_datasets
      end
    end

    def prune_datasets
      txg_timeout = File.read('/sys/module/zfs/parameters/zfs_txg_timeout').strip.to_i

      @trash_dataset.list(depth: 1, include_self: false).each do |ds|
        break if @stop

        unless ds.name.start_with?("#{@trash_dataset}/")
          raise "programming error: refusing to destroy dataset #{ds.name.inspect}"
        end

        log(:info, "Destroying #{ds}")

        begin
          ds.destroy!(recursive: true)
        rescue SystemCommandFailed => e
          log(:warn, "Unable to destroy #{ds}: #{e.message}")
          next
        end

        break if @stop

        sleep([txg_timeout, 5].max)
      end
    end

    def trash_path(dataset)
      t = Time.now

      path = File.join(
        @trash_dataset.name,
        [
          dataset.name.split('/')[1..-1].join('-'),
          t.to_i,
          SecureRandom.hex(3)
        ].join('.')
      )

      [path, t]
    end
  end
end
