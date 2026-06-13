require 'osctld/local_transfer'
require 'osctld/transfer/log'

module OsCtld
  class LocalTransfer::Log < Transfer::Log
    class Dataset
      attr_reader :relative_name, :source, :target

      def self.load(cfg)
        new(
          relative_name: cfg['relative_name'],
          source: cfg['source'],
          target: cfg['target']
        )
      end

      def initialize(relative_name:, source:, target:)
        @relative_name = relative_name
        @source = source
        @target = target
      end

      def dump
        {
          'relative_name' => relative_name,
          'source' => source,
          'target' => target
        }
      end
    end

    class Options
      attr_reader :operation, :target_pool, :target_id, :target_dataset,
                  :target_dataset_custom, :target_user, :target_group,
                  :network_interfaces, :from_snapshot, :datasets

      def self.load(cfg)
        new(cfg.transform_keys(&:to_sym))
      end

      def initialize(opts)
        opts = opts.dup

        @operation = opts.delete(:operation).to_sym
        @target_pool = opts.delete(:target_pool)
        @target_id = opts.delete(:target_id)
        @target_dataset = opts.delete(:target_dataset)
        @target_dataset_custom = opts.delete(:target_dataset_custom) || false
        @target_user = opts.delete(:target_user)
        @target_group = opts.delete(:target_group)
        @network_interfaces = opts.delete(:network_interfaces)
        @from_snapshot = opts.delete(:from_snapshot)
        @datasets = (opts.delete(:datasets) || []).map do |v|
          v.is_a?(Dataset) ? v : Dataset.load(v)
        end

        return if opts.empty?

        raise ArgumentError, "unsupported options: #{opts.keys.join(', ')}"
      end

      def copy?
        operation == :copy
      end

      def move?
        operation == :move
      end

      def dump
        {
          'operation' => operation.to_s,
          'target_pool' => target_pool,
          'target_id' => target_id,
          'target_dataset' => target_dataset,
          'target_dataset_custom' => target_dataset_custom,
          'target_user' => target_user,
          'target_group' => target_group,
          'network_interfaces' => network_interfaces,
          'from_snapshot' => from_snapshot,
          'datasets' => datasets.map(&:dump)
        }
      end
    end

    def self.load(cfg)
      new(
        role: cfg['role'].to_sym,
        state: cfg['state'].to_sym,
        snapshots: cfg['snapshots'] || [],
        state_snapshot: cfg['state_snapshot'],
        state_running: cfg['state_running'],
        opts: Options.load(cfg['opts'])
      )
    end

    def initialize(opts)
      super(opts.merge(opts: opts[:opts].is_a?(Options) ? opts[:opts] : Options.new(opts[:opts] || {})))
    end

    def dump
      {
        'role' => role.to_s,
        'state' => state.to_s,
        'snapshots' => snapshots,
        'state_snapshot' => state_snapshot,
        'state_running' => state_running,
        'opts' => opts.dump
      }
    end

    def can_local_continue?(next_state)
      can_continue?(next_state, sync_states: %i[incremental])
    end

    def can_local_cancel?(force = false)
      can_cancel?(force)
    end

    def close; end
  end
end
