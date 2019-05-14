require 'libosctl/exporter/base'

module OsCtl::Lib
  # Handles dumping containers as ZFS streams into tar archives
  #
  # Usage:
  #
  #   exporter.dump_rootfs do
  #     # Create a snapshot a dump it
  #     exporter.dump_base
  #
  #     # Create another snapshot and dump it as an incremental stream
  #     # from the base snapshot
  #     exporter.dump_incremental
  #   end
  class Exporter::Zfs < Exporter::Base
    include Utils::Log
    include Utils::System

    def initialize(*_)
      super

      @datasets = ct.datasets[1..-1] # skip the root dataset
      @snapshots = []
    end

    # Method used to wrap dumping of base and incremental data streams of rootfs
    #
    # @yield [] call {#dump_base} and {#dump_incremental} from within the block
    def dump_rootfs
      tar.mkdir('rootfs', DIR_MODE)

      each_dataset_dir do |_ds, dir|
        tar.mkdir(File.join('rootfs', dir), DIR_MODE)
      end

      yield

      snapshots.reverse!

      each_dataset do |ds|
        snapshots.each do |snap|
          zfs(:destroy, '', "#{ds}@#{snap}")
        end
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

      each_dataset_file('base') do |ds, file|
        dump_stream(file, ds, base_snap)
      end
    end

    # Dump incremental data stream from the base stream
    #
    # Should be called from within the block given to {#dump_rootfs}.
    def dump_incremental(from_snap: nil)
      snap = snapshot(ct.dataset, 'incr')

      each_dataset_file('incremental') do |ds, file|
        dump_stream(file, ds, snap, from_snap || base_snap)
      end
    end

    def format
      :zfs
    end

    protected
    attr_reader :snapshots, :base_snap

    # Iterate over all datasets
    # @yieldparam ds [Zfs::Dataset]
    def each_dataset(&block)
      block.call(ct.dataset)
      datasets.each(&block)
    end

    # Iterate over all datasets and yield the dataset along with directory name
    # for the tar archive, where its streams will be stored.
    #
    # @yieldparam ds [Zfs::Dataset]
    # @yieldparam dir_name [String] directory name within the archive
    def each_dataset_dir
      each_dataset do |ds|
        yield(ds, ds.relative_name)
      end
    end

    # Iterate over all datasets and yield the dataset along with file name for
    # the archive.
    #
    # @param name [String] base/incremental
    # @yieldparam ds [Zfs::Dataset]
    # @yieldparam fname [String] file name within the archive
    def each_dataset_file(name)
      each_dataset_dir do |ds, dir|
        yield(ds, File.join(dir, name))
      end
    end

    def snapshot_name(type)
      "osctl-#{type}-#{Time.now.to_i}"
    end

    def snapshot(dataset, type)
      snap = snapshot_name(type)
      zfs(:snapshot, '-r', "#{dataset}@#{snap}")
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
        elsif zfs(:get, "-H -o value compression", dataset).output.strip == 'off'
          :gzip
        else
          :off
        end

      else
        opts[:compression].to_sym
      end
    end

    def dump_file_name(compression, name)
      base = File.join('rootfs', "#{name}.dat")

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
