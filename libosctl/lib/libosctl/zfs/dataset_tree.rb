module OsCtl::Lib
  # Encapsulates a tree of datasets and their properties
  class Zfs::DatasetTree
    # @return [String, nil] full name
    attr_reader :name

    # @return [Hash<String, String>]
    attr_reader :properties

    # @return [Hash<String, Zfs::DatasetTree>]
    attr_reader :datasets

    # @param name [String]
    def initialize(name: nil)
      @name = name
      @properties = {}
      @datasets = {}
    end

    # Add property to a dataset
    # @param dataset [String]
    # @param property [String]
    # @param value [String]
    def add_property(dataset, property, value)
      parts = dataset.split('/')
      do_add_property([], parts.first, parts[1..-1], property, value)
    end

    # Lookup dataset in the subtree
    # @param dataset [String] full name
    # @return [Zfs::DatasetTree, nil]
    def [](dataset)
      parts = dataset.split('/')
      tree = self

      parts.each do |name|
        tree = tree.datasets[name]
        return nil if tree.nil?
      end

      tree
    end

    # Iterate over all datasets in the subtree
    # @yieldparam tree [Zfs::DatasetTree]
    def each_tree_dataset(&block)
      block.call(self)
      datasets.each_value { |ds| ds.each_tree_dataset(&block) }
    end

    # @return [Zfs::Dataset]
    def as_dataset(base: '')
      Zfs::Dataset.new(name, base:, properties:)
    end

    # Print the tree to the console
    def print(indent: 0)
      puts "#{' ' * indent}#{name}:"

      properties.each do |k, v|
        puts "#{' ' * indent}  #{k}=#{v}"
      end

      datasets.each_value do |tree|
        tree.print(indent: indent + 2)
      end
    end

    protected

    def do_add_property(path, name, parts, property, value)
      datasets[name] ||= self.class.new(name: (path + [name]).join('/'))

      if parts.empty?
        datasets[name].properties[property] = value
      else
        datasets[name].do_add_property(
          path + [name],
          parts.first,
          parts[1..-1],
          property,
          value
        )
      end
    end
  end
end
