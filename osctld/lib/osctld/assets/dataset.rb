module OsCtld
  class Assets::Dataset < Assets::Base
    register :dataset

    include Utils::Log
    include Utils::System
    include Utils::Zfs

    # @param opts [Hash] options
    # @option opts [Integer, nil] uidoffset
    # @option opts [Integer, nil] gidoffset
    # @option opts [Integer, nil] user
    # @option opts [Integer, nil] group
    # @option opts [Integer, nil] mode
    def initialize(path, opts)
      super
    end

    def valid?
      ret = zfs(
        :get,
        '-H -ovalue mountpoint,uidoffset,gidoffset',
        path,
        valid_rcs: [1]
      )

      if ret[:exitstatus] > 0
        add_error('does not exist')
        return super
      end

      @mountpoint, uidoffset, gidoffset = ret[:output].split("\n")

      if opts[:user] && stat.uid != opts[:user]
        add_error('invalid owner')
      end

      if opts[:group] && stat.gid != opts[:group]
        add_error('invalid group')
      end

      if opts[:mode] && mode != opts[:mode]
        add_error('invalid mode')
      end

      if opts[:uidoffset] && opts[:uidoffset] != uidoffset.to_i
        add_error('invalid uidoffset')
      end

      if opts[:gidoffset] && opts[:gidoffset] != gidoffset.to_i
        add_error('invalid gidoffset')
      end

      super
    end

    protected
    def stat
      @stat ||= File.stat(@mountpoint)
    end

    def mode
      # Extract permission bits, see man inode(7)
      stat.mode & 07777
    end
  end
end
