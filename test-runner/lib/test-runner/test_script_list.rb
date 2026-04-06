module TestRunner
  class TestScriptList
    def initialize(system: NixCli::DEFAULT_SYSTEM, test_config_path: nil)
      @test_list = TestList.new(system:, test_config_path:)
    end

    # Return a list of all known test scripts
    # @return [Array<TestScript>]
    def all
      expand_scripts(@test_list.all)
    end

    # Filter through all test scripts, return those that the filter matched
    # @yieldparam [TestScript]
    # @return [Array<TestScript>]
    def filter(&)
      all.select(&)
    end

    # Return one test script specified by path
    # @return [TestScript]
    def by_path(path)
      test_path, script_name = path.split('#')

      test = @test_list.by_path(test_path)

      if script_name
        script = test.test_scripts[script_name]
        raise "Test #{test_path} does not have script ##{script_name}" if script.nil?

        script
      elsif test.test_scripts.length == 1
        test.test_scripts.first[1]
      else
        raise "Test #{test_path} has scripts #{test.test_scripts.each_key.map { |v| "##{v}" }.join(', ')}, choose one"
      end
    end

    protected

    def expand_scripts(test_list)
      ret = []

      test_list.each do |test|
        test.test_scripts.each_value do |ts|
          ret << ts
        end
      end

      ret
    end
  end
end
