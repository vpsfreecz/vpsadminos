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

    # @return [Integer]
    attr_reader :attempts

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
      @attempts = opts[:attempts]
      @expect_failure = opts[:expect_failure]
      @tags = opts[:tags]
      @labels = opts[:labels]
      @test_scripts = opts[:test_scripts].to_h do |ts_name, ts_opts|
        [
          ts_name,
          TestScript.new(
            self,
            ts_name,
            description: ts_opts['description'],
            expect_failure: ts_opts['expectFailure'],
            tags: ts_opts.fetch('tags', []),
            labels: ts_opts.fetch('labels', {})
          )
        ]
      end

      return if @test_scripts.length != 1 || !@test_scripts.has_key?('default')

      @test_scripts['default'].set_singleton
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
