require 'osctl/template/operations/base'

module OsCtl::Template
  class Operations::Test::Template < Operations::Base
    # @return [String]
    attr_reader :base_dir

    # @return [Template]
    attr_reader :template

    # @param base_dir [String]
    # @param template [Template]
    # @param tests [Array<Test>]
    # @param opts [Hash]
    # @option opts [String] :build_dataset
    # @option opts [String] :output_dir
    # @option opts [String] :vendor
    # @option opts [Boolean] :rebuild
    def initialize(base_dir, template, tests, opts)
      @base_dir = base_dir
      @template = template
      @tests = tests
      @opts = opts
    end

    # @return [Array<Operations::Test::Run::Status>]
    def execute
      build = Operations::Template::Build.new(base_dir, template, opts)
      build.execute if opts[:rebuild] || !build.cached?

      tests.map do |test|
        Operations::Test::Run.run(base_dir, build, test)
      end
    end

    protected
    attr_reader :tests, :opts
  end
end
