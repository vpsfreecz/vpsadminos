require 'osctld/assets/base_file'

module OsCtld
  class Assets::Directory < Assets::BaseFile
    register :directory

    def valid?
      add_error('not a directory') if exist? && !opts[:optional] && !stat.directory?
      super

    rescue Errno::ENOENT
      add_error('does not exist')
      false
    end
  end
end
