require 'osctld/assets/base'

module OsCtld
  class Assets::BaseFile < Assets::Base
    register :file

    # @param opts [Hash] options
    # @option opts [Integer, nil] user
    # @option opts [Integer, nil] group
    # @option opts [Integer, nil] mode
    # @option opts [Integer, nil] mode_bit_and
    # @option opts [Boolean] optional
    def initialize(path, opts) # rubocop:disable all
      super
    end

    def exist?
      File.exist?(path)
    end

    protected

    def validate(run)
      return if !exist? && opts[:optional]

      begin
        if opts[:user] && stat.uid != opts[:user]
          add_error("invalid owner: expected #{opts[:user]}, got #{stat.uid}")
        end

        if opts[:group] && stat.gid != opts[:group]
          add_error("invalid group: expected #{opts[:group]}, got #{stat.gid}")
        end

        if opts[:mode] && mode != opts[:mode]
          add_error("invalid mode: expected #{opts[:mode].to_s(8)}, got #{mode.to_s(8)}")
        end

        if opts[:mode_bit_and] && (mode & opts[:mode_bit_and]) != opts[:mode_bit_and]
          add_error("invalid mode: bitwise and with #{opts[:mode_bit_and].to_s(8)} does not match")
        end
      rescue Errno::ENOENT
        add_error('does not exist')
      end

      super
    end

    def stat
      @stat ||= File.stat(path)
    end

    def mode
      # Extract permission bits, see man inode(7)
      stat.mode & 0o7777
    end
  end
end
