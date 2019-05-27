module OsCtl::Template
  class TestList < Array
    # @param base_dir [String]
    def initialize(base_dir)
      Operations::Config::ParseList.run(base_dir, :test).each do |name|
        self << Test.new(base_dir, name)
      end
    end
  end
end
