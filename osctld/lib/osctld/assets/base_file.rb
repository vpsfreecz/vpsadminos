require 'osctld/assets/base'

module OsCtld
  class Assets::BaseFile < Assets::Base
    register :file

    # @param opts [Hash] options
    # @option opts [Integer, nil] user
    # @option opts [Integer, nil] group
    # @option opts [Integer, nil] mode
    # @option opts [Boolean] optional
    def initialize(path, opts)
      super
    end

    def valid?
      return true if !exist? && opts[:optional]

      if opts[:user] && stat.uid != opts[:user]
        add_error("invalid owner: expected #{opts[:user]}, got #{stat.uid}")
      end

      if opts[:group] && stat.gid != opts[:group]
        add_error("invalid group: expected #{opts[:group]}, got #{stat.gid}")
      end

      if opts[:mode] && mode != opts[:mode]
        add_error("invalid mode: expected #{opts[:mode].to_s(8)}, got #{mode.to_s(8)}")
      end

      super

    rescue Errno::ENOENT
      add_error('does not exist')
      false
    end

    def exist?
      File.exist?(path)
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
