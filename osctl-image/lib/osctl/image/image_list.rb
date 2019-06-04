module OsCtl::Image
  class ImageList < Array
    # @param base_dir [String]
    def initialize(base_dir)
      Operations::Config::ParseList.run(base_dir, :image).each do |name|
        self << Image.new(base_dir, name)
      end
    end
  end
end
