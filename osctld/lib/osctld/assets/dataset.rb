require 'libosctl'
require 'osctld/assets/base'

module OsCtld
  class Assets::Dataset < Assets::Base
    register :dataset

    # @param opts [Hash] options
    # @option opts [Array, nil] uidmap
    # @option opts [Array, nil] gidmap
    # @option opts [Integer, nil] user
    # @option opts [Integer, nil] group
    # @option opts [Integer, nil] mode
    # @option opts [Integer, nil] mode_bit_and
    def initialize(path, opts)
      super
    end

    def prefetch_zfs
      [[path], %w(mountpoint uidmap gidmap)]
    end

    protected
    def validate(run)
      ds = run.dataset_tree[path]

      if ds.nil?
        add_error('does not exist')
        return super
      end

      @mountpoint = ds.properties['mountpoint']
      uidmap = ds.properties['uidmap']
      gidmap = ds.properties['gidmap']

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

      if opts[:uidmap]
        expected_uidmap = make_ugid_map(opts[:uidmap])

        if expected_uidmap != uidmap
          add_error("invalid uidmap: expected #{expected_uidmap}, got #{uidmap}")
        end
      end

      if opts[:gidmap]
        expected_gidmap = make_ugid_map(opts[:gidmap])

        if expected_gidmap != gidmap
          add_error("invalid gidmap: expected #{expected_gidmap}, got #{gidmap}")
        end
      end

      super
    end

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
