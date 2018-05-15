require 'osctld/assets/base'

module OsCtld
  class Assets::Symlink < Assets::BaseFile
    register :symlink

    def valid?
      add_error('not a symlink') if exist? && !opts[:optional] && !stat.symlink?
      super

    rescue Errno::ENOENT
      add_error('does not exist')
      false
    end

    protected
    def stat
      @stat ||= File.lstat(path)
    end
  end
end
