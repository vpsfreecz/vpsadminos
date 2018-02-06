require 'yaml'
require 'rubygems'
require 'rubygems/package'
require 'zlib'

module VpsAdminOS::Converter
  # Handles dumping containers into tar archives
  class Exporter
    DIR_MODE = 16877 # 0755
    FILE_MODE = 33188 # 0644

    include Utils::System
    include Utils::Zfs

    # @param ct [Container]
    # @param io [IO]
    # @param opts [Hash]
    # @option opts [Symbol] compression auto/off/gzip
    # @option opts [Boolean] compressed_send
    def initialize(ct, io, opts = {})
      @ct = ct
      @tar = Gem::Package::TarWriter.new(io)
      @opts = opts
      @snapshots = []
    end

    # Dump important metadata describing the archive
    def dump_metadata(type)
      tar.add_file('metadata.yml', FILE_MODE) do |tf|
        tf.write(YAML.dump(
          'type' => type,
          'user' => ct.user.name,
          'group' => ct.group.name,
          'container' => ct.id,
          'exported_at' => Time.now.to_i,
        ))
      end
    end

    # Dump configuration of the container, its user and group
    def dump_configs
      tar.mkdir('config', DIR_MODE)
      tar.add_file('config/user.yml', FILE_MODE) do |tf|
        tf.write(YAML.dump(ct.user.dump_config))
      end
      tar.add_file('config/group.yml', FILE_MODE) do |tf|
        tf.write(YAML.dump(ct.group.dump_config))
      end
      tar.add_file('config/container.yml', FILE_MODE) do |tf|
        tf.write(YAML.dump(ct.dump_config))
      end
    end

    # Method used to wrap dumping of base and incremental data streams of rootfs
    #
    # @yield [] call {#dump_base_stream} and {#dump_incremental_stream} from
    #           within the block
    def dump_rootfs_stream
      tar.mkdir('rootfs', DIR_MODE)

      yield

      snapshots.reverse!.each do |snap|
        zfs(:destroy, '', "#{ct.dataset}@#{snap}")
      end

      tar.add_file('snapshots.yml', FILE_MODE) do |tf|
        tf.write(YAML.dump(snapshots))
      end
    end

    # Dump initial data stream
    #
    # Should be called from within the block given to {#dump_rootfs_stream}.
    def dump_base_stream
      @base_snap = snapshot(ct.dataset, 'base')
      dump_stream('base', ct.dataset, base_snap)
    end

    # Dump incremental data stream from the base stream
    #
    # Should be called from within the block given to {#dump_rootfs_stream}.
    def dump_incremental_stream(from_snap: nil)
      snap = snapshot(ct.dataset, 'incr')
      dump_stream('incremental', ct.dataset, snap, from_snap || base_snap)
    end

    def close
      tar.close
    end

    protected
    attr_reader :ct, :tar, :opts, :snapshots, :base_snap

    def snapshot_name(type)
      "vpsadminos-converter-#{type}-#{Time.now.to_i}"
    end

    def snapshot(dataset, type)
      snap = snapshot_name(type)
      zfs(:snapshot, '', "#{dataset}@#{snap}")
      snapshots << snap
      snap
    end

    def dump_stream(name, dataset, snap, from_snap = nil)
      compression = get_compression(dataset)

      if from_snap
        cmd = "#{zfs_send} -I @#{from_snap} #{dataset}@#{snap}"
      else
        cmd = "#{zfs_send} #{dataset}@#{snap}"
      end

      tar.add_file(dump_file_name(compression, name), FILE_MODE) do |tf|
        IO.popen("exec #{cmd}") do |io|
          process_stream(compression, io, tf)
        end

        if $?.exitstatus != 0
          fail "zfs send failed with exit status #{$?.exitstatus}"
        end
      end
    end

    def process_stream(compression, stream, tf)
      case compression
      when :gzip
        gz = Zlib::GzipWriter.new(tf)
        gz.write(stream.read(16*1024)) until stream.eof?
        gz.close

      when :off
        tf.write(stream.read(16*1024)) until stream.eof?

      else
        fail "unexpected compression type '#{compression}'"
      end
    end

    def get_compression(dataset)
      case opts[:compression]
      when :auto
        if !opts[:compressed_send]
          :gzip
        elsif zfs(:get, "-H -o value compression", dataset)[:output].strip == 'off'
          :gzip
        else
          :off
        end

      else
        opts[:compression]
      end
    end

    def dump_file_name(compression, name)
      base = "rootfs/#{name}.dat"

      case compression
      when :gzip
        "#{base}.gz"

      else
        base
      end
    end

    def zfs_send
      if opts[:compressed_send]
        'zfs send -c'

      else
        'zfs send'
      end
    end
  end
end
