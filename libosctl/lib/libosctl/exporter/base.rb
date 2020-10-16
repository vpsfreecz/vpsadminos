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

    class ConfigDump
      %i(user group container).each do |name|
        define_method(name) do |v = nil|
          var = :"@#{name}"

          if v
            instance_variable_set(var, v)
          else
            instance_variable_get(var)
          end
        end
      end
    end

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
    # @param type ['skel', 'full']
    # @param opts [Hash] options
    # @option opts [String] :id custom container id
    # @option opts [String] :user custom user name
    # @option opts [String] :group custom group name
    def dump_metadata(type, opts = {})
      tar.add_file('metadata.yml', FILE_MODE) do |tf|
        tf.write(YAML.dump(
          'type' => type,
          'format' => format.to_s,
          'user' => opts[:user] || (ct.user && ct.user.name),
          'group' => opts[:group] || (ct.group && ct.group.name),
          'container' => opts[:id] || ct.id,
          'datasets' => datasets.map { |ds| ds.relative_name },
          'exported_at' => Time.now.to_i,
        ))
      end
    end

    # Dump configuration of the container, its user and group
    #
    # If no block is given, user/group/container configs are dumped as they are.
    # Configs can be altered by passing a block, which will get {ConfigDump}
    # as an argument.
    #
    # @yieldparam dump [ConfigDump]
    def dump_configs
      dump = ConfigDump.new
      tar.mkdir('config', DIR_MODE)

      if block_given?
        yield(dump)
      else
        dump.user(File.read(ct.user.config_path)) if ct.user
        dump.group(File.read(ct.group.config_path)) if ct.group

        if ct.respond_to?(:dump_config)
          dump.container(YAML.dump(ct.dump_config))
        elsif ct.respond_to?(:config_path)
          dump.container(File.read(ct.config_path))
        else
          fail "don't know how to dump container config"
        end
      end

      if dump.user
        tar.add_file('config/user.yml', FILE_MODE) do |tf|
          tf.write(dump.user)
        end
      end

      if dump.group
        tar.add_file('config/group.yml', FILE_MODE) do |tf|
          tf.write(dump.group)
        end
      end

      if dump.container
        tar.add_file('config/container.yml', FILE_MODE) do |tf|
          tf.write(dump.container)
        end
      else
        fail 'container config not set'
      end
    end

    # Dump user script hooks, if there is at least one present
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
