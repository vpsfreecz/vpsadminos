module OsCtl::Template
  class TemplateList < Array
    # @param base_dir [String]
    def initialize(base_dir)
      Operations::Config::ParseList.run(base_dir, :template).each do |name|
        self << Template.new(base_dir, name)
      end
    end
  end
end
