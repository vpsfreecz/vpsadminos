module TestRunner
  class TestScriptList
    # Return a list of all known test scripts
    # @return [Array<TestScript>]
    def all
      expand_scripts(TestList.new.all)
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

      TestList.new.by_path(test_path).test_scripts.detect { |ts| ts.name == script_name }
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
