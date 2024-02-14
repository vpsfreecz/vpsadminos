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
          canmount: 'noauto'
        }
      }
      zfs_opts[:parents] = true if opts[:parents]

      if opts[:uid_map]
        zfs_opts[:properties][:uidmap] = opts[:uid_map].map(&:to_s).join(',')
      end

      if opts[:gid_map]
        zfs_opts[:properties][:gidmap] = opts[:gid_map].map(&:to_s).join(',')
      end

      ds.create!(**zfs_opts)
      ds.mount(recursive: true)
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
        syscmd("zfs send -p -L #{from ? "-i @#{from}" : ''} #{src_ds}@#{snap} " \
               "| zfs recv -F #{dst_ds}")
      end

      snap
    end

    # @param image [String] image path
    # @param dir [String] dir to extract it to
    # @param opts [Hash] options
    # @option opts [String] :distribution
    # @option opts [String] :version
    def from_local_archive(image, dir, _opts = {})
      progress('Extracting image')
      syscmd("tar -xzf #{image} -C #{dir}")
      shift_dataset
    end

    # @param image [String] image path
    # @param member [String] file from the tar to use
    # @param compression [:gzip, :off] compression type
    # @param ds [OsCtl::Lib::Zfs::Dataset]
    def from_tar_stream(image, member, compression, ds)
      progress('Writing data stream')

      commands = [
        ['tar', '-xOf', image, member]
      ]

      case compression
      when :gzip
        commands << ['gunzip']
      when :off
        # no command
      else
        raise "unexpected compression type '#{compression}'"
      end

      commands << ['zfs', 'recv', '-F', ds.to_s]

      command_string = commands.map { |c| c.join(' ') }.join(' | ')

      # Note that we intentionally use shell to run the pipeline. Whenever ruby
      # is more involved in the process, we start to experience random deadlocks
      # when the zfs receive hangs.
      pid = Process.spawn(command_string)
      Process.wait(pid)

      if $?.exitstatus != 0
        raise "failed to import stream: command '#{command_string}' " \
              "exited with #{$?.exitstatus}"
      end

      nil
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
        raise 'provide uid_map or gid_map'
      end

      zfs(:unmount, nil, ds, valid_rcs: [1])
      zfs(:set, set_opts.join(' '), ds)

      5.times do |i|
        zfs(:mount, nil, ds)

        f = Tempfile.create(['.ugid-map-test'], ds.mountpoint)
        f.close

        st = File.stat(f.path)
        File.unlink(f.path)

        if (opts[:uid_map] && st.uid == opts[:uid_map].ns_to_host(0)) \
           || (opts[:gid_map] && st.gid == opts[:gid_map].ns_to_host(0))
          return
        end

        zfs(:unmount, nil, ds)
        sleep(1 + i)
      end

      raise 'unable to configure UID/GID mapping'
    end

    protected

    def progress(msg)
      return unless @builder_opts[:cmd]

      @builder_opts[:cmd].send(:progress, msg)
    end
  end
end
