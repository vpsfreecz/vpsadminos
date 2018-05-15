require 'osctld/assets/base'

module OsCtld
  class Assets::File < Assets::BaseFile
    register :file

    def valid?
      add_error('not a file') if exist? && !opts[:optional] && !stat.file?
      super

    rescue Errno::ENOENT
      add_error('does not exist')
      false
    end
  end
end
