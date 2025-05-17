module TestRunner::Cli
  class TagFilters
    # @param str_tags [Array<String>]
    def initialize(str_tags)
      @must = []
      @cant = []
      parse_all(str_tags)
    end

    # @param test [TestRunner::Test]
    def pass?(test)
      must.all? { |t| test.tags.include?(t) } \
        && cant.all? { |t| !test.tags.include?(t) }
    end

    protected

    attr_reader :must, :cant

    def parse_all(str_tags)
      str_tags.each do |t|
        if t.start_with?('^')
          cant << t[1..]
        else
          must << t
        end
      end
    end
  end
end
