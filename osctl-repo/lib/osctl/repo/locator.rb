module OsCtl
  module Repo
    def self.root
      File.absolute_path(File.join(__dir__, '..', '..', '..'))
    end
  end
end
