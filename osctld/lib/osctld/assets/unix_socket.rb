require 'osctld/assets/base'

module OsCtld
  class Assets::UnixSocket < Assets::BaseFile
    register :socket

    def valid?
      add_error('not a socket') if exist? && !opts[:optional] && !stat.socket?
      super

    rescue Errno::ENOENT
      add_error('does not exist')
      false
    end
  end
end
