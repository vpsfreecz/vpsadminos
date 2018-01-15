module OsCtld
  class Assets::Dataset < Assets::Base
    register :dataset

    include Utils::Log
    include Utils::System
    include Utils::Zfs

    # @param opts [Hash] options
    # @opt opts [Integer, nil] uidoffset
    # @opt opts [Integer, nil] gidoffset
    def initialize(path, opts)
      super
    end

    def valid?
      ret = zfs(:get, '-H -ovalue uidoffset,gidoffset', path, valid_rcs: [1])

      if ret[:exitstatus] > 0
        add_error('does not exist')
        return super
      end

      uidoffset, gidoffset = ret[:output].split("\n").map(&:to_i)

      if opts[:uidoffset] && opts[:uidoffset] != uidoffset
        add_error('invalid uidoffset')
      end

      if opts[:gidoffset] && opts[:gidoffset] != gidoffset
        add_error('invalid gidoffset')
      end

      super
    end
  end
end
