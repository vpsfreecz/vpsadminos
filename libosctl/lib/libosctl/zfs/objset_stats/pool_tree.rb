module OsCtl::Lib
  class Zfs::ObjsetStats::PoolTree
    attr_reader :pool, :root

    # @param pool [String]
    def initialize(pool)
      @pool = pool
      @list = []
      @index = {}
      @root = nil
    end

    # @param objset [Zfs::ObjsetStats::Objset]
    def <<(objset)
      @list << objset
      @index[objset.dataset_name] = objset
      @root = objset if objset.dataset_name == pool
    end

    # @param name [String]
    def [](name)
      @index[name]
    end

    def build
      sorted = @list.sort { |a, b| a.dataset_name <=> b.dataset_name }
      sorted.shift

      parent_stack = [root]

      sorted.each do |objset|
        parent_n = 0

        parent_stack.reverse_each.with_index do |parent, i|
          if objset.dataset_name.start_with?("#{parent.dataset_name}/")
            parent.subdatasets << objset
            break
          end

          parent_n = i + 1
        end

        parent_stack = parent_stack[ 0 .. (parent_stack.size - parent_n) ]
        parent_stack << objset
      end

      @list.clear
    end

    def print(objset, indent: 0)
      puts "#{' ' * indent}#{objset.dataset_name}:"
      objset.subdatasets.each do |subset|
        print(subset, indent: indent + 2)
      end
    end
  end
end
