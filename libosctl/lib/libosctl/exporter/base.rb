require 'yaml'
require 'rubygems'
require 'rubygems/package'
require 'zlib'

module OsCtl::Lib
  # Handles dumping containers into tar archives
  #
  # This base class can dump only archive metadata and config files.
  # To export the container's rootfs, use either {Exporter::Zfs} or
  # {Exporter::Tar}.
  class Exporter::Base
    DIR_MODE = 16877 # 0755
    FILE_MODE = 33188 # 0644

    # @param ct [Container]
    # @param io [IO]
    # @param opts [Hash]
    # @option opts [Symbol] compression auto/off/gzip
    # @option opts [Boolean] compressed_send
    def initialize(ct, io, opts = {})
      @ct = ct
      @tar = Gem::Package::TarWriter.new(io)
      @opts = opts
      @datasets = []
    end

    # Dump important metadata describing the archive
    def dump_metadata(type)
      tar.add_file('metadata.yml', FILE_MODE) do |tf|
        tf.write(YAML.dump(
          'type' => type,
          'format' => format.to_s,
          'user' => ct.user.name,
          'group' => ct.group.name,
          'container' => ct.id,
          'datasets' => datasets.map { |ds| ds.relative_name },
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

    # Dump user hook scripts, if there is at least one present
    # @param supported_hooks [Array<Symbol>]
    def dump_user_hook_scripts(supported_hooks)
      dir = ct.user_hook_script_dir
      hooks = Dir.entries(dir).map do |f|
        path = File.join(dir, f)

        [path, f, File.lstat(path)]

      end.select do |path, name, st|
        supported_hooks.include?(name.gsub(/-/, '_').to_sym) && st.file?
      end

      return if hooks.empty?

      tar.mkdir('hooks', DIR_MODE)

      hooks.each do |path, name, _st|
        add_file_from_disk(path, File.join('hooks', name))
      end
    end

    def close
      tar.close
    end

    def format; nil; end

    protected
    attr_reader :ct, :tar, :opts, :datasets, :base_snap

    # Add file from disk to the created tar archive
    # @param src [String] path on disk
    # @param dst [String] path in tar
    def add_file_from_disk(src, dst)
      st = File.stat(src)

      tar.add_file(dst, st.mode) do |tf|
        File.open(src, 'r') { |df| IO.copy_stream(df, tf) }
      end
    end
  end
end
