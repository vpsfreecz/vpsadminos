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
    include OsCtl::Lib::Utils::Log
    include OsCtl::Lib::Utils::File

    USER = 'repository'.freeze
    UID = Etc.getpwnam(USER).uid

    DEFAULT_PRUNE_INTERVAL = 24 * 60 * 60
    DEFAULT_PRUNE_OLDER_THAN_DAYS = 90

    # @return [Pool]
    attr_reader :pool

    # @return [String]
    attr_reader :name

    # @return [String]
    attr_reader :url

    # @return [Boolean]
    attr_reader :enabled
    alias enabled? enabled

    # @return [Boolean]
    attr_reader :prune_enabled

    # @return [Integer]
    attr_reader :prune_interval

    # @return [Integer]
    attr_reader :prune_older_than_days

    # @return [Attributes]
    attr_reader :attrs

    def initialize(pool, name, load: true)
      init_lock
      init_manipulable
      @pool = pool
      @name = name
      @enabled = true
      @attrs = Attributes.new
      @prune_thread = nil
      @prune_queue = OsCtl::Lib::Queue.new
      load_config if load
    end

    def id
      name
    end

    def ident
      "#{pool.name}:#{name}"
    end

    def configure(url, prune_enabled: true, prune_interval: DEFAULT_PRUNE_INTERVAL, prune_older_than_days: DEFAULT_PRUNE_OLDER_THAN_DAYS)
      @url = url
      @prune_enabled = prune_enabled
      @prune_interval = prune_interval
      @prune_older_than_days = prune_older_than_days
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

        when :prune_enabled
          @prune_enabled = true
          start_prune

        when :prune_interval
          @prune_interval = v

        when :prune_older_than_days
          @prune_older_than_days = v

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
        when :prune_enabled
          @prune_enabled = false
          stop_prune

        when :attrs
          v.each { |attr| attrs.unset(attr) }

        else
          raise "unsupported option '#{k}'"
        end
      end

      save_config
    end

    # @return [Array(Boolean, Array<String>)] status and a list of deleted image files, if any
    def prune_images(older_than_days: nil)
      OsCtlRepo.new(self).prune_images(older_than_days:)
    end

    def images
      # TODO
    end

    def start
      start_prune if @prune_enabled
    end

    def stop
      stop_prune
    end

    def export
      {
        pool: pool.name,
        name: name,
        url: url,
        enabled: enabled,
        prune_enabled: prune_enabled,
        prune_interval: prune_interval,
        prune_older_than_days: prune_older_than_days
      }
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

    def log_type
      "repository #{ident}"
    end

    protected

    attr_reader :state

    def load_config
      cfg = OsCtl::Lib::ConfigFile.load_yaml_file(config_path)

      @url = cfg['url']
      @enabled = cfg['enabled']
      @prune_enabled = cfg.fetch('prune_enabled', true)
      @prune_interval = cfg.fetch('prune_interval', DEFAULT_PRUNE_INTERVAL)
      @prune_older_than_days = cfg.fetch('prune_older_than_days', DEFAULT_PRUNE_OLDER_THAN_DAYS)
      @attrs = Attributes.load(cfg['attrs'] || {})
    end

    def save_config
      regenerate_file(config_path, 0o400) do |f|
        f.write(OsCtl::Lib::ConfigFile.dump_yaml({
          'url' => url,
          'enabled' => enabled?,
          'prune_enabled' => prune_enabled,
          'prune_interval' => prune_interval,
          'prune_older_than_days' => prune_older_than_days,
          'attrs' => attrs.dump
        }))
      end

      File.chown(0, 0, config_path)
    end

    def start_prune
      return if @prune_thread

      @prune_thread = Thread.new do
        loop do
          v = @prune_queue.pop(timeout: @prune_interval)
          break if v == :stop || !@prune_enabled

          log(:info, 'Starting periodic prune')
          prune_images(older_than_days: @prune_older_than_days)
        end
      end
    end

    def stop_prune
      return if @prune_thread.nil?

      @prune_queue << :stop
      @prune_thread.join
      @prune_thread = nil
    end
  end
end
