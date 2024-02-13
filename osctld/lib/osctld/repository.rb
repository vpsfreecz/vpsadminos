require 'etc'
require 'libosctl'
require 'osctld/lockable'
require 'osctld/manipulable'
require 'osctld/assets/definition'

module OsCtld
  class Repository
    include Lockable
    include Manipulable
    include Assets::Definition

    USER = 'repository'
    UID = Etc.getpwnam(USER).uid

    attr_reader :pool, :name, :url, :attrs

    def initialize(pool, name, load: true)
      init_lock
      init_manipulable
      @pool = pool
      @name = name
      @enabled = true
      @attrs = Attributes.new
      load_config if load
    end

    def id
      name
    end

    def configure(url)
      @url = url
      save_config
    end

    def assets
      define_assets do |add|
        add.file(
          config_path,
          desc: 'Configuration file',
          user: 0,
          group: 0,
          mode: 0o400
        )
        add.directory(
          cache_path,
          desc: 'Local cache',
          user: UID,
          group: 0,
          mode: 0o700
        )
      end
    end

    def enabled?
      @enabled
    end

    def disabled?
      !enabled?
    end

    def enable
      @enabled = true
      save_config
    end

    def disable
      @enabled = false
      save_config
    end

    # @param opts [Hash]
    # @option opts [Hash] :attrs
    def set(opts)
      opts.each do |k, v|
        case k
        when :url
          @url = v

        when :attrs
          attrs.update(v)

        else
          raise "unsupported option '#{k}'"
        end
      end

      save_config
    end

    # @param opts [Hash]
    # @option opts [Array<String>] :attrs
    def unset(opts)
      opts.each do |k, v|
        case k
        when :attrs
          v.each { |attr| attrs.unset(attr) }

        else
          raise "unsupported option '#{k}'"
        end
      end

      save_config
    end

    def images
      # TODO
    end

    def config_path
      File.join(pool.conf_path, 'repository', "#{name}.yml")
    end

    def cache_path
      File.join(pool.repo_path, name)
    end

    def manipulation_resource
      ['repository', "#{pool.name}:#{name}"]
    end

    protected

    attr_reader :state

    def load_config
      cfg = OsCtl::Lib::ConfigFile.load_yaml_file(config_path)

      @url = cfg['url']
      @enabled = cfg['enabled']
      @attrs = Attributes.load(cfg['attrs'] || {})
    end

    def save_config
      File.open(config_path, 'w', 0o400) do |f|
        f.write(OsCtl::Lib::ConfigFile.dump_yaml({
          'url' => url,
          'enabled' => enabled?,
          'attrs' => attrs.dump
        }))
      end

      File.chown(0, 0, config_path)
    end
  end
end
