require 'libosctl'

module OsCtld
  # Ensures that temporary datasets are moved to trash after they're not needed
  #
  # It can be used to tie datasets to specific container runs. Add dataset using
  # {#add_container_run_dataset} and it will be kept as long as the same run configuration
  # is active. When the container is stopped, restarted, or {#free_container_run_dataset}
  # is called, the dataset is moved to the trash bin.
  class GarbageCollector
    class ContainerRunDataset
      def self.load(cfg)
        new(
          Container::RunId.load(cfg['run_id']),
          OsCtl::Lib::Zfs::Dataset.new(cfg['dataset'])
        )
      end

      # @return [Container::RunId]
      attr_reader :run_id

      # @return [OsCtl::Lib::Zfs::Dataset]
      attr_reader :dataset

      # @param run_id [Container::RunId]
      # @param dataset [OsCtl::Lib::Zfs::Dataset]
      def initialize(run_id, dataset)
        @run_id = run_id
        @dataset = dataset
      end

      def pool_name
        run_id.pool_name
      end

      def container_id
        run_id.container_id
      end

      def dump
        {
          'run_id' => run_id.dump,
          'dataset' => dataset.name
        }
      end

      def ==(other)
        other.run_id == run_id && other.dataset.name == dataset.name
      end
    end

    # @param run_conf [Container::RunConfiguration]
    # @param dataset [OsCtl::Lib::Zfs::Dataset]
    def self.add_container_run_dataset(run_conf, dataset)
      run_conf.pool.garbage_collector.add_container_run_dataset(run_conf, dataset)
    end

    # @param run_conf [Container::RunConfiguration]
    # @param dataset [OsCtl::Lib::Zfs::Dataset]
    def self.free_container_run_dataset(run_conf, dataset)
      run_conf.pool.garbage_collector.free_container_run_dataset(run_conf, dataset)
    end

    include Lockable
    include OsCtl::Lib::Utils::Log
    include OsCtl::Lib::Utils::File

    # @return [Pool]
    attr_reader :pool

    # @param pool [Pool]
    def initialize(pool)
      init_lock
      @pool = pool
      @config_path = File.join(pool.conf_path, 'pool', 'garbage-collector.yml')
      @queue = OsCtl::Lib::Queue.new
      @stop = false

      load_config
    end

    def assets(add)
      add.file(
        @config_path,
        desc: 'Configuration file for garbage collector',
        optional: true
      )
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

    def started?
      !@stop
    end

    def prune
      @queue << :prune
    end

    # @param run_conf [Container::RunConfiguration]
    # @param dataset [OsCtl::Lib::Zfs::Dataset]
    def add_container_run_dataset(run_conf, dataset)
      exclusively do
        @container_run_datasets << ContainerRunDataset.new(run_conf.run_id, dataset)
        save_config
      end
    end

    # @param run_conf [Container::RunConfiguration]
    # @param dataset [OsCtl::Lib::Zfs::Dataset]
    def free_container_run_dataset(run_conf, dataset)
      @queue << [:free_container_run_dataset, ContainerRunDataset.new(run_conf.run_id, dataset)]
    end

    def log_type
      "#{pool.name}:gc"
    end

    protected

    def load_config
      @container_run_datasets = []

      begin
        cfg = OsCtl::Lib::ConfigFile.load_yaml_file(@config_path)
      rescue Errno::ENOENT
        return
      end

      @container_run_datasets = cfg.fetch('container_run_datasets', []).map do |ct_run_ds_cfg|
        ContainerRunDataset.load(ct_run_ds_cfg)
      end
    end

    def save_config
      exclusively do
        regenerate_file(@config_path, 0o400) do |f|
          f.write(OsCtl::Lib::ConfigFile.dump_yaml({
            'container_run_datasets' => @container_run_datasets.map(&:dump)
          }))
        end
      end
    end

    def run_gc
      loop do
        v = @queue.pop(timeout: Daemon.get.config.garbage_collector.prune_interval)

        case v
        in :stop
          return

        in :prune | nil
          log(:info, 'Pruning container run datasets')
          prune_container_run_datasets

        in [:free_container_run_dataset, ct_run_ds]
          do_free_container_run_dataset(ct_run_ds)
        end
      end
    end

    def prune_container_run_datasets
      unused =
        inclusively do
          @container_run_datasets.reject do |ct_run_ds|
            container_run_dataset_in_use?(ct_run_ds)
          end
        end

      unused.each do |ct_run_ds|
        break if @stop

        log(:info, "Container dataset #{ct_run_ds.dataset} from run=#{ct_run_ds.run_id} is no longer in use, moving to trash")
        next unless trash_dataset(ct_run_ds.dataset)

        exclusively do
          @container_run_datasets.delete(ct_run_ds)
          save_config
        end
      end
    end

    def do_free_container_run_dataset(ct_run_ds)
      # It may be that the dataset wasn't previously registered within the GC.
      # It could be a dataset that existed before GC support was introduced. In any
      # case, the intent is to delete the dataset and so we do not perform a lookup
      # in @container_run_datasets.
      log(:info, "Moving #{ct_run_ds.dataset} to trash")
      return unless trash_dataset(ct_run_ds.dataset)

      exclusively do
        @container_run_datasets.delete(ct_run_ds)
        save_config
      end
    end

    def container_run_dataset_in_use?(ct_run_ds)
      ct = DB::Containers.find(ct_run_ds.container_id, ct_run_ds.pool_name)
      return false if ct.nil?

      run_conf = ct.run_conf
      next_run_conf = ct.next_run_conf

      (run_conf && run_conf.run_id == ct_run_ds.run_id) \
        || (next_run_conf && next_run_conf.run_id == ct_run_ds.run_id)
    end

    # @return [Boolean] true if the dataset was moved to trash or if it doesn't exist
    def trash_dataset(dataset)
      pool.trash_bin.add_dataset(dataset)
      true
    rescue SystemCommandFailed => e
      if dataset.exist?
        log(:warn, "Unable to trash dataset '#{dataset}': #{e.message}")
        false
      else
        log(:warn, "Attempted to trash a non-existent dataset '#{dataset}' (original error: #{e.message})")
        true
      end
    end
  end
end
