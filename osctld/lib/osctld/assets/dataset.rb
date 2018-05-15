require 'libosctl'
require 'osctld/assets/base'

module OsCtld
  class Assets::Dataset < Assets::Base
    register :dataset

    include OsCtl::Lib::Utils::Log
    include OsCtl::Lib::Utils::System

    # @param opts [Hash] options
    # @option opts [Array, nil] uidmap
    # @option opts [Array, nil] gidmap
    # @option opts [Integer, nil] user
    # @option opts [Integer, nil] group
    # @option opts [Integer, nil] mode
    def initialize(path, opts)
      super
    end

    def valid?
      ret = zfs(
        :get,
        '-H -ovalue mountpoint,uidmap,gidmap',
        path,
        valid_rcs: [1]
      )

      if ret[:exitstatus] > 0
        add_error('does not exist')
        return super
      end

      @mountpoint, uidmap, gidmap = ret[:output].split("\n")

      if opts[:user] && stat.uid != opts[:user]
        add_error('invalid owner')
      end

      if opts[:group] && stat.gid != opts[:group]
        add_error('invalid group')
      end

      if opts[:mode] && mode != opts[:mode]
        add_error('invalid mode')
      end

      if opts[:uidmap] && make_ugid_map(opts[:uidmap]) != uidmap
        add_error('invalid uidmap')
      end

      if opts[:gidmap] && make_ugid_map(opts[:gidmap]) != gidmap
        add_error('invalid gidmap')
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

    def make_ugid_map(arr)
      arr.map do |entry|
        entry.join(':')
      end.join(',')
    end
  end
end
