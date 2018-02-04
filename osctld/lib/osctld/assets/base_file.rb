module OsCtld
  class Assets::BaseFile < Assets::Base
    register :file

    # @param opts [Hash] options
    # @opt opts [Integer, nil] user
    # @opt opts [Integer, nil] group
    # @opt opts [Integer, nil] mode
    def initialize(path, opts)
      super
    end

    def valid?
      if opts[:user] && stat.uid != opts[:user]
        add_error('invalid owner')
      end

      if opts[:group] && stat.gid != opts[:group]
        add_error('invalid group')
      end

      if opts[:mode] && mode != opts[:mode]
        add_error('invalid mode')
      end

      super

    rescue Errno::ENOENT
      add_error('does not exist')
      false
    end

    protected
    def stat
      @stat ||= File.stat(path)
    end

    def mode
      # Extract permission bits, see man inode(7)
      stat.mode & 07777
    end
  end
end
