module OsCtl::Image
  class Test
    # @return [String]
    attr_reader :base_dir

    # @return [String]
    attr_reader :name

    # @param base_dir [String]
    # @param name [String]
    def initialize(base_dir, name)
      @base_dir = base_dir
      @name = name
    end

    def to_s
      name
    end
  end
end
