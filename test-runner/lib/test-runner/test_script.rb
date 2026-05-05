module TestRunner
  class TestScript
    # @return [Test]
    attr_reader :test

    # @return [String]
    attr_reader :name

    # @return [String]
    attr_reader :path

    # @return [String]
    attr_reader :description

    # @return [Boolean, nil]
    attr_reader :expect_failure

    # @return [Integer]
    attr_reader :attempts

    # @return [Array<String>]
    attr_reader :tags

    # @return [Hash<String, String>]
    attr_reader :labels

    def initialize(test, name, description:, expect_failure:, attempts:, tags:, labels:)
      @test = test
      @name = name
      @path = "#{test.path}##{name}"
      @description = description || test.description
      @expect_failure = expect_failure.nil? ? test.expect_failure : expect_failure
      @attempts = attempts || test.attempts || 1
      @tags = test.tags + tags
      @labels = test.labels.merge(labels)
      @singleton = false
    end

    # @param pattern [String]
    def path_matches?(pattern)
      File.fnmatch?(pattern, path, File::FNM_EXTGLOB)
    end

    def set_singleton
      @path = test.path
      @singleton = true
    end

    def singleton?
      @singleton
    end
  end
end
