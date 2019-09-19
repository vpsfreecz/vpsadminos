module OsCtl::ExportFS
  module Config
    # @param path [String]
    # @return [TopLevel]
    def self.open(path)
      TopLevel.new(path)
    end
  end
end
