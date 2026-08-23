require 'yaml'

module OsCtld
  # Boot-bound start intents captured by switch-to-configuration while
  # replacing a daemon which predates durable lifecycle generations.
  class UpgradeHandoff
    PATH = '/run/osctl/upgrade-handoff.yml'.freeze
    BOOT_ID_PATH = '/proc/sys/kernel/random/boot_id'.freeze
    SOURCE = 'legacy-runtime-upgrade'.freeze
    ROOT_KEYS = %w[
      boot_id containers created_at runtime_containers schema
    ].freeze

    def self.load(path = PATH, boot_id_path: BOOT_ID_PATH)
      cfg = YAML.safe_load_file(path, permitted_classes: [], aliases: false)
      return invalid(path, 'handoff root is not a mapping') unless cfg.is_a?(Hash)

      boot_id = cfg['boot_id']
      return invalid(path, 'boot_id is missing or invalid') unless boot_id.is_a?(String)
      return new(path, [], []) unless boot_id == File.read(boot_id_path).strip
      return invalid(path, "unsupported schema #{cfg['schema'].inspect}") unless cfg['schema'] == 1

      valid_created_at = cfg['created_at'].is_a?(Numeric) \
        && cfg['created_at'].finite? \
        && cfg['created_at'] >= 0
      unless cfg.keys.sort == ROOT_KEYS && valid_created_at
        return invalid(path, 'handoff root has invalid fields')
      end

      entries = load_entries(cfg, 'containers', runtime: false)
      runtime_entries = load_entries(cfg, 'runtime_containers', runtime: true)
      new(path, entries, runtime_entries)
    rescue Errno::ENOENT
      new(path, [], [])
    rescue ArgumentError => e
      invalid(path, e.message)
    rescue Psych::Exception => e
      invalid(path, "invalid YAML: #{e.message}")
    end

    def self.load_entries(cfg, key, runtime:)
      value = cfg[key]
      raise ArgumentError, "#{key} is not an array" unless value.is_a?(Array)

      seen = {}
      value.map.with_index do |entry, index|
        allowed_keys = runtime ? %w[id pool source] : %w[id pool priority source]
        required_keys = %w[id pool source]
        valid = entry.is_a?(Hash) \
          && (entry.keys - allowed_keys).empty? \
          && (required_keys - entry.keys).empty? \
          && entry['pool'].is_a?(String) \
          && !entry['pool'].empty? \
          && entry['id'].is_a?(String) \
          && !entry['id'].empty? \
          && entry['source'] == SOURCE \
          && (runtime || !entry.has_key?('priority') || entry['priority'].is_a?(Integer))
        unless valid
          raise ArgumentError, "#{key}[#{index}] is invalid"
        end

        identity = [entry['pool'], entry['id']]
        fields = runtime ? true : [entry.has_key?('priority'), entry['priority']]
        if seen.has_key?(identity) && seen[identity] != fields
          raise ArgumentError, "#{key}[#{index}] conflicts with an earlier entry"
        end

        seen[identity] = fields
        identity
      end
    end

    def self.invalid(path, message)
      new(path, [], [], error: message)
    end

    def initialize(path, entries, runtime_entries = [], error: nil)
      @path = path
      @entries = entries.uniq
      @runtime_entries = runtime_entries.uniq
      @error = error
      @mutex = Mutex.new
    end

    attr_reader :error

    def valid?
      error.nil?
    end

    def include?(ct)
      @mutex.synchronize { @entries.include?([ct.pool.name, ct.id]) }
    end

    def fulfil(ct)
      @mutex.synchronize { @entries.delete([ct.pool.name, ct.id]) }
    end

    def runtime?(ct)
      @mutex.synchronize do
        @runtime_entries.include?([ct.pool.name, ct.id])
      end
    end

    def fulfil_runtime(ct)
      @mutex.synchronize do
        @runtime_entries.delete([ct.pool.name, ct.id])
      end
    end

    def empty?
      @mutex.synchronize { @entries.empty? && @runtime_entries.empty? }
    end

    def remaining
      @mutex.synchronize { @entries.map(&:dup) }
    end

    def remaining_runtime
      @mutex.synchronize { @runtime_entries.map(&:dup) }
    end

    # Remove the handoff only after every imported pool has persisted the
    # matching desired-running lifecycle intent. Until then, a daemon SIGKILL
    # can safely reload and replay the same boot-bound file.
    def complete
      return false unless valid? && empty?

      File.unlink(@path)
      true
    rescue Errno::ENOENT
      true
    end
  end
end
