module OsCtld
  class Assets::Directory < Assets::BaseFile
    register :directory

    def valid?
      add_error('not a directory') unless stat.directory?
      super

    rescue Errno::ENOENT
      add_error('does not exist')
      false
    end
  end
end
