require 'osctld/assets/base'

module OsCtld
  class Assets::Symlink < Assets::BaseFile
    register :symlink

    protected
    def validate(run)
      begin
        add_error('not a symlink') if exist? && !opts[:optional] && !stat.symlink?
      rescue Errno::ENOENT
        add_error('does not exist')
      end

      super
    end

    def stat
      @stat ||= File.lstat(path)
    end
  end
end
