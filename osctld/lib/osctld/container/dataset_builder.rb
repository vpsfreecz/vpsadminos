require 'libosctl'
require 'tempfile'

module OsCtld
  class Container::DatasetBuilder
    include OsCtl::Lib::Utils::Log
    include OsCtl::Lib::Utils::System
    include Utils::SwitchUser

    # @param opts [Hash]
    # @option opts [Command::Base] :cmd
    def initialize(opts = {})
      @builder_opts = opts
    end

    # @param ds [OsCtl::Lib::Zfs::Dataset]
    # @param opts [Hash] options
    # @option opts [OsCtl::Lib::IdMap] :uid_map
    # @option opts [OsCtl::Lib::IdMap] :gid_map
    # @option opts [Boolean] :parents
    def create_dataset(ds, opts = {})
      zfs_opts = {
        properties: {
          canmount: 'noauto',
        },
      }
      zfs_opts[:parents] = true if opts[:parents]

      if opts[:uid_map]
        zfs_opts[:properties][:uidmap] = opts[:uid_map].map(&:to_s).join(',')
      end

      if opts[:gid_map]
        zfs_opts[:properties][:gidmap] = opts[:gid_map].map(&:to_s).join(',')
      end

      ds.create!(zfs_opts)
    end

    # @param src [Array<OsCtl::Lib::Zfs::Dataset>]
    # @param dst [Array<OsCtl::Lib::Zfs::Dataset>]
    # @param from [String, nil] base snapshot
    # @return [String] snapshot name
    def copy_datasets(src, dst, from: nil)
      snap = "osctl-copy-#{from ? 'incr' : 'base'}-#{Time.now.to_i}"
      zfs(:snapshot, nil, src.map { |ds| "#{ds}@#{snap}" }.join(' '))

      zipped = src.zip(dst)

      zipped.each do |src_ds, dst_ds|
        progress("Copying dataset #{src_ds.relative_name}")
        syscmd("zfs send -c -p -L #{from ? "-i @#{from}" : ''} #{src_ds}@#{snap} "+
               "| zfs recv -F #{dst_ds}")
      end

      snap
    end

    # @param ds [OsCtl::Lib::Zfs::Dataset]
    def from_stream(ds)
      progress('Writing image stream')

      IO.popen("exec zfs recv -F #{ds}", 'r+') do |io|
        yield(io)
      end

      if $?.exitstatus != 0
        fail "zfs recv failed with exit status #{$?.exitstatus}"
      end
    end

    # @param ds [OsCtl::Lib::Zfs::Dataset]
    # @param opts [Hash] options
    # @option opts [OsCtl::Lib::IdMap] :uid_map
    # @option opts [OsCtl::Lib::IdMap] :gid_map
    def shift_dataset(ds, opts = {})
      progress('Configuring UID/GID mapping')

      set_opts = []

      if opts[:uid_map]
        set_opts << "\"uidmap=#{opts[:uid_map].map(&:to_s).join(',')}\""
      end

      if opts[:gid_map]
        set_opts << "\"gidmap=#{opts[:gid_map].map(&:to_s).join(',')}\""
      end

      if set_opts.empty?
        fail 'provide uid_map or gid_map'
      end

      zfs(:set, set_opts.join(' '), ds)
    end

    protected
    def progress(msg)
      return unless @builder_opts[:cmd]
      @builder_opts[:cmd].send(:progress, msg)
    end
  end
end
