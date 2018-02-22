module OsCtl
  module Repo
    def self.root
      File.absolute_path(File.join(File.dirname(__FILE__), '..', '..', '..'))
    end
  end
end
