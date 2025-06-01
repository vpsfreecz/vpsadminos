module TestRunner
  class Test
    # @return [String]
    attr_reader :path

    # @return [String]
    attr_reader :type

    # @return [String]
    attr_reader :template

    # @return [Hash]
    attr_reader :template_args

    # @return [Hash]
    attr_reader :test_args

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

    # @return [Hash<String, TestScript>]
    attr_reader :test_scripts

    # @param opts [Hash]
    def initialize(**opts)
      @path = opts[:path]
      @type = opts[:type]
      @template = opts[:template]
      @template_args = opts[:template_args]
      @test_args = opts[:test_args]
      @name = opts[:name]
      @description = opts[:description]
      @expect_failure = opts[:expect_failure]
      @tags = opts[:tags]
      @labels = opts[:labels]
      @test_scripts = opts[:test_scripts].to_h do |ts_name, ts_opts|
        [
          ts_name,
          TestScript.new(
            self,
            ts_name,
            expect_failure: ts_opts['expectFailure'],
            tags: ts_opts.fetch('tags', []),
            labels: ts_opts.fetch('labels', {})
          )
        ]
      end
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
