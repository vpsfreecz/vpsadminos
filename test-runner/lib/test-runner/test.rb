module TestRunner
  class Test
    # @return [String]
    attr_reader :path

    # @return [String]
    attr_reader :type

    # @return [String]
    attr_reader :template

    # @return [Hash]
    attr_reader :args

    # @return [String]
    attr_reader :name

    # @return [String]
    attr_reader :description

    # @return [Boolean]
    attr_reader :expect_failure

    # @return [Array<String>]
    attr_reader :tags

    # @return [Hash<String, String>]
    attr_reader :labels

    # @param opts [Hash]
    def initialize(**opts)
      @path = opts[:path]
      @type = opts[:type]
      @template = opts[:template]
      @args = opts[:args]
      @name = opts[:name]
      @description = opts[:description]
      @expect_failure = opts[:expect_failure]
      @tags = opts[:tags]
      @labels = opts[:labels]
    end

    # @param pattern [String]
    def path_matches?(pattern)
      File.fnmatch?(pattern, path, File::FNM_EXTGLOB)
    end

    def template?
      type == 'template'
    end

    def file_path
      if template?
        "#{template}.nix"
      else
        "#{path}.nix"
      end
    end
  end
end
