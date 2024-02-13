require 'osctld/assets/base'

module OsCtld
  class Assets::File < Assets::BaseFile
    register :file

    protected

    def validate(run)
      begin
        add_error('not a file') if exist? && !opts[:optional] && !stat.file?
      rescue Errno::ENOENT
        add_error('does not exist')
      end

      super
    end
  end
end
