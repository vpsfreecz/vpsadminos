require 'thread'

module OsCtld
  # Thread-safe singleton object list
  class DB::List
    @@instances = {}

    class << self
      def instance
        @@instances[self] = new unless @@instances.has_key?(self)
        @@instances[self]
      end

      %i(sync get count add remove find contains?).each do |v|
        define_method(v) do |*args, &block|
          instance.send(v, *args, &block)
        end
      end
    end

    private
    def initialize
      @mutex = Mutex.new
      @objects = []
    end

    public
    def sync(&block)
      if @mutex.owned?
        block.call
      else
        @mutex.synchronize { block.call }
      end
    end

    def get(&block)
      sync do
        if block
          block.call(@objects)
        else
          @objects.clone
        end
      end
    end

    def count
      sync { @objects.count }
    end

    def add(obj)
      sync { @objects << obj }

      Eventd.report(
        :db,
        object: obj.class.name.split('::').last.downcase,
        pool: obj.pool.name,
        id: obj.id,
        action: :add
      )
    end

    def remove(obj)
      sync { @objects.delete(obj) }

      Eventd.report(
        :db,
        object: obj.class.name.split('::').last.downcase,
        pool: obj.pool.name,
        id: obj.id,
        action: :remove
      )
    end

    def find(id, &block)
      sync do
        obj = @objects.detect { |v| v.id == id }

        if block
          block.call(obj)
        else
          obj
        end
      end
    end

    def contains?(id)
      !find(id).nil?
    end

    protected
    attr_reader :objects
  end
end
