module TestRunner
  class Test
    attr_reader :path, :type, :template, :args, :name, :description

    # @param opts [Hash]
    def initialize(**opts)
      @path = opts[:path]
      @type = opts[:type]
      @template = opts[:template]
      @args = opts[:args]
      @name = opts[:name]
      @description = opts[:description]
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
