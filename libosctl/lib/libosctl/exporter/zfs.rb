require 'open3'
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

      @datasets = ct.datasets[1..] # skip the root dataset
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

      tar.add_file('snapshots.yml', FILE_MODE) do |tf|
        tf.write(ConfigFile.dump_yaml(snapshots.reverse))
      end
    ensure
      each_dataset do |ds|
        snapshots.reverse_each do |snap|
          zfs(:destroy, '', "#{ds}@#{snap}")
        end
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
      statuses = nil

      cmd = if from_snap
              "#{zfs_send} -I @#{from_snap} #{dataset}@#{snap}"
            else
              "#{zfs_send} #{dataset}@#{snap}"
            end

      tar.add_file(dump_file_name(compression, name), FILE_MODE) do |tf|
        statuses = process_stream(compression, cmd, tf)
      end

      check_stream_statuses(compression, statuses)
    end

    def process_stream(compression, command, tf)
      pipeline =
        case compression
        when :gzip
          ["exec #{command}", resolve_command(gzip_command)]
        when :off
          ["exec #{command}"]
        else
          raise "unexpected compression type '#{compression}'"
        end

      statuses = nil

      Open3.pipeline_r(*pipeline) do |stream, wait_threads|
        IO.copy_stream(stream, tf)
        statuses = wait_threads.map(&:value)
      end

      statuses
    end

    def gzip_command
      ['gzip', '-c']
    end

    def resolve_command(command)
      [find_executable!(command.fetch(0)), *command.drop(1)]
    end

    def check_stream_statuses(compression, statuses)
      processes = [['zfs send', statuses.fetch(0)]]
      processes << ['gzip', statuses.fetch(1)] if compression == :gzip

      failures = processes.filter_map do |name, status|
        next if status.success?

        if status.exited?
          "#{name} failed with exit status #{status.exitstatus}"
        else
          "#{name} was terminated by signal #{status.termsig}"
        end
      end

      raise failures.join('; ') unless failures.empty?
    end

    def get_compression(dataset)
      case opts[:compression]
      when :auto
        if !opts[:compressed_send] || zfs(:get, '-H -o value compression', dataset).output.strip == 'off'
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
