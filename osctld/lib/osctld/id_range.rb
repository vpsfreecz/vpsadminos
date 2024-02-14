require 'libosctl'
require 'osctld/lockable'
require 'osctld/manipulable'
require 'osctld/assets/definition'

module OsCtld
  class IdRange
    class AllocationError < StandardError; end

    include Lockable
    include Manipulable
    include Assets::Definition

    attr_reader :pool, :name, :start_id, :block_size, :block_count, :attrs

    def initialize(pool, name, load: true)
      init_lock
      init_manipulable
      @pool = pool
      @name = name
      @attrs = Attributes.new
      load_config if load
    end

    def id
      name
    end

    def configure(start_id, block_size, block_count)
      exclusively do
        @start_id = start_id
        @block_size = block_size
        @block_count = block_count
        @allocations = AllocationTable.new(block_count)
        save_config
      end
    end

    # @param block_count [Integer] number of blocks to allocate
    # @param opts [Hash]
    # @option opts [Integer] :block_index optional starting block_index
    # @option opts [String] :owner
    # @return [Hash]
    def allocate(block_count, opts = {})
      ret = nil

      exclusively do
        if opts[:block_index]
          begin
            ret = allocations.allocate_at(opts[:block_index], block_count, opts[:owner])
          rescue ArgumentError => e
            raise AllocationError, e.message
          end
        else
          unless (ret = allocations.allocate(block_count, opts[:owner]))
            raise AllocationError, 'no free space found'
          end
        end
        save_config
      end

      add_block_ids(ret)
    end

    # @param block_index [Integer]
    def free_at(block_index)
      exclusively do
        unless allocations.free_at(block_index)
          raise AllocationError, "block at index #{block_index} not found"
        end

        save_config
      end
    end

    # @param owner [String]
    def free_by(owner)
      exclusively do
        allocations.free_by(owner)
        save_config
      end
    end

    def can_delete?
      allocations.empty?
    end

    def assets
      define_assets do |add|
        add.file(
          config_path,
          desc: 'Configuration file',
          user: 0,
          group: 0,
          mode: 0o400
        )
      end
    end

    # @param opts [Hash]
    # @option opts [Hash] :attrs
    def set(opts)
      opts.each do |k, v|
        case k
        when :attrs
          attrs.update(v)

        else
          raise "unsupported option '#{k}'"
        end
      end

      save_config
    end

    # @param opts [Hash]
    # @option opts [Array<String>] :attrs
    def unset(opts)
      opts.each do |k, v|
        case k
        when :attrs
          v.each { |attr| attrs.unset(attr) }

        else
          raise "unsupported option '#{k}'"
        end
      end

      save_config
    end

    def last_id
      start_id + (block_size * block_count) - 1
    end

    def export
      inclusively do
        {
          pool: pool.name,
          name:,
          start_id:,
          last_id:,
          block_size:,
          block_count:,
          allocated: allocations.count_allocated_blocks,
          free: allocations.count_free_blocks
        }.merge!(attrs.export)
      end
    end

    def export_all
      inclusively do
        allocations.export_all.map { |v| add_block_ids(v) }
      end
    end

    def export_allocated
      inclusively do
        allocations.export_allocated.map { |v| add_block_ids(v) }
      end
    end

    def export_free
      inclusively do
        allocations.export_free.map { |v| add_block_ids(v) }
      end
    end

    # @param block_index [Integer]
    def export_at(block_index)
      inclusively do
        add_block_ids(allocations.export_at(block_index))
      end
    end

    def config_path
      File.join(pool.conf_path, 'id-range', "#{name}.yml")
    end

    def manipulation_resource
      ['id-range', "#{pool.name}:#{name}"]
    end

    protected

    attr_reader :allocations

    def add_block_ids(block)
      first_id = start_id + (block[:block_index] * block_size)
      block.merge(
        first_id:,
        last_id: first_id + (block_size * block[:block_count]) - 1,
        id_count: block_size * block[:block_count]
      )
    end

    def load_config
      cfg = OsCtl::Lib::ConfigFile.load_yaml_file(config_path)

      @start_id = cfg['start_id']
      @block_size = cfg['block_size']
      @block_count = cfg['block_count']
      @allocations = AllocationTable.load(block_count, cfg['allocations'])
      @attrs = Attributes.load(cfg['attrs'] || {})
    end

    def save_config
      File.open(config_path, 'w', 0o400) do |f|
        f.write(OsCtl::Lib::ConfigFile.dump_yaml({
          'start_id' => start_id,
          'block_size' => block_size,
          'block_count' => block_count,
          'allocations' => allocations.dump,
          'attrs' => attrs.dump
        }))
      end

      File.chown(0, 0, config_path)
    end
  end
end
