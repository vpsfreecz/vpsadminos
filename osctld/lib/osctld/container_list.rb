module OsCtld
  class ContainerList
    @@instance = nil

    def self.instance
      @@instance = new unless @@instance
      @@instance
    end

    def self.sync(&block)
      instance.sync(&block)
    end

    def self.get(&block)
      instance.get(&block)
    end

    def self.add(ct)
      instance.add(ct)
    end

    def self.remove(ct)
      instance.remove(ct)
    end

    def self.find(id, &block)
      instance.find(id)
    end

    private
    def initialize
      @mutex = Mutex.new
      @cts = []
      @@instance = self
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
          block.call(@cts)
        else
          @cts.clone
        end
      end
    end

    def add(ct)
      sync { @cts << ct }
    end

    def remove(ct)
      sync { @cts.delete(ct) }
    end

    def find(id, &block)
      sync do
        ct = @cts.detect { |ct| ct.id == id }

        if block
          block.call(ct)
        else
          ct
        end
      end
    end
  end
end
