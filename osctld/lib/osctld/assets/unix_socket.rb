require 'osctld/assets/base'

module OsCtld
  class Assets::UnixSocket < Assets::BaseFile
    register :socket

    protected

    def validate(run)
      begin
        add_error('not a socket') if exist? && !opts[:optional] && !stat.socket?
      rescue Errno::ENOENT
        add_error('does not exist')
      end

      super
    end
  end
end
