module TestRunner
  class TestScript
    # @return [Test]
    attr_reader :test

    # @return [String]
    attr_reader :name

    # @return [String]
    attr_reader :path

    # @return [Boolean, nil]
    attr_reader :expect_failure

    # @return [Array<String>]
    attr_reader :tags

    # @return [Hash<String, String>]
    attr_reader :labels

    def initialize(test, name, expect_failure:, tags:, labels:)
      @test = test
      @name = name
      @path = "#{test.path}##{name}"
      @expect_failure = expect_failure.nil? ? test.expect_failure : expect_failure
      @tags = test.tags + tags
      @labels = test.labels.merge(labels)
    end

    # @param pattern [String]
    def path_matches?(pattern)
      File.fnmatch?(pattern, path, File::FNM_EXTGLOB)
    end
  end
end
