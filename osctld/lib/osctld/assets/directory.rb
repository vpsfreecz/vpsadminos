require 'osctld/assets/base_file'

module OsCtld
  class Assets::Directory < Assets::BaseFile
    register :directory

    protected

    def validate(run)
      begin
        add_error('not a directory') if exist? && !opts[:optional] && !stat.directory?
      rescue Errno::ENOENT
        add_error('does not exist')
      end

      super
    end
  end
end
