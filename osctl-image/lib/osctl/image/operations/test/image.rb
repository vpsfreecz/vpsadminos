require 'osctl/image/operations/base'

module OsCtl::Image
  class Operations::Test::Image < Operations::Base
    # @return [String]
    attr_reader :base_dir

    # @return [Image]
    attr_reader :image

    # @param base_dir [String]
    # @param image [Image]
    # @param tests [Array<Test>]
    # @param opts [Hash]
    # @option opts [String] :build_dataset
    # @option opts [String] :output_dir
    # @option opts [String] :vendor
    # @option opts [Boolean] :rebuild
    def initialize(base_dir, image, tests, opts)
      @base_dir = base_dir
      @image = image
      @tests = tests
      @opts = opts
    end

    # @return [Array<Operations::Test::Run::Status>]
    def execute
      build = Operations::Image::Build.new(base_dir, image, opts)
      build.execute if opts[:rebuild] || !build.cached?

      tests.map do |test|
        Operations::Test::Run.run(base_dir, build, test)
      end
    end

    protected
    attr_reader :tests, :opts
  end
end
