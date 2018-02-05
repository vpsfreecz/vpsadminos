require 'yaml'
require 'rubygems'
require 'rubygems/package'
require 'zlib'

module OsCtld
  # Handles dumping containers into tar archives
  class Container::Exporter
    DIR_MODE = 16877 # 0755
    FILE_MODE = 33188 # 0644

    include Utils::Log
    include Utils::System
    include Utils::Zfs

    # @param ct [Container]
    # @param io [IO]
    # @param opts [Hash]
    # @option opts [Symbol] compression auto/off/gzip
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
        tf.write(File.read(ct.user.config_path))
      end
      tar.add_file('config/group.yml', FILE_MODE) do |tf|
        tf.write(File.read(ct.group.config_path))
      end
      tar.add_file('config/container.yml', FILE_MODE) do |tf|
        tf.write(File.read(ct.config_path))
      end
    end

    # Method used to wrap dumping of base and incremental data streams of rootfs
    #
    # @yield [] call {#dump_base} and {#dump_incremental} from within the block
    def dump_rootfs
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
    # Should be called from within the block given to {#dump_rootfs}.
    def dump_base
      @base_snap = snapshot(ct.dataset, 'base')
      dump_stream('base', ct.dataset, base_snap)
    end

    # Dump incremental data stream from the base stream
    #
    # Should be called from within the block given to {#dump_rootfs}.
    def dump_incremental(from_snap: nil)
      snap = snapshot(ct.dataset, 'incr')
      dump_stream('incremental', ct.dataset, snap, from_snap || base_snap)
    end

    def close
      tar.close
    end

    protected
    attr_reader :ct, :tar, :opts, :snapshots, :base_snap

    def snapshot_name(type)
      "osctl-#{type}-#{Time.now.to_i}"
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
        cmd = "zfs send -c -I @#{from_snap} #{dataset}@#{snap}"
      else
        cmd = "zfs send -c #{dataset}@#{snap}"
      end

      tar.add_file(dump_file_name(compression, name), FILE_MODE) do |tf|
        IO.popen("exec #{cmd}") do |io|
          process_stream(compression, io, tf)
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
        if zfs(:get, "-H -o value compression", dataset)[:output].strip == 'off'
          :gzip
        else
          :off
        end

      else
        opts[:compression].to_sym
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
  end
end
