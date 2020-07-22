module TestRunner
  class Test
    attr_reader :path, :name, :description

    # @param opts [Hash]
    def initialize(opts)
      @path = opts[:path]
      @name = opts[:name]
      @description = opts[:description]
    end

    # @param pattern [String]
    def path_matches?(pattern)
      File.fnmatch?(pattern, path, File::FNM_EXTGLOB)
    end
  end
end
