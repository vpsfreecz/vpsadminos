module OsCtld
  # {IdMap} represents ID mappings for user namespaces, be it user or group IDs
  class IdMap
    Entry = Struct.new(:ns_id, :host_id, :count) do
      def self.from_string(str)
        ns_id, host_id, cnt = str.split(':')
        Entry.new(ns_id.to_i, host_id.to_i, cnt.to_i)
      end

      def to_a
        [ns_id, host_id, count]
      end

      def to_s
        "#{ns_id}:#{host_id}:#{count}"
      end
    end

    # Load map from config file
    #
    # We're still backward compatible with UID/GID offsets, which are converted
    # to a map with a single entry. Remove this in the future (TODO).
    #
    # @return [IdMap]
    def self.load(cfg, old_cfg = nil)
      if old_cfg && cfg.nil? && old_cfg['offset'] && old_cfg['size']
        new(["0:#{old_cfg['offset']}:#{old_cfg['size']}"])

      else
        new(cfg || [])
      end
    end

    def initialize(str_entries = [])
      @entries = str_entries.map { |str| Entry.from_string(str) }
    end

    def valid?
      return false if ns_to_host(0) < 0

      entries.each do |e|
        return false if e.ns_id < 0 || e.host_id < 0 || e.count < 1
      end

      true

    rescue IdMappingError
      false
    end

    # Dump the map to config file
    def dump
      entries.map(&:to_s)
    end

    # Export the map to clients
    def export
      dump
    end

    def each(&block)
      entries.each(&block)
    end

    include Enumerable

    # Map ID from the namespace to the host
    def ns_to_host(id)
      entries.each do |e|
        if id >= e.ns_id && id < (e.ns_id + e.count)
          return e.host_id + (id - e.ns_id)
        end
      end

      raise IdMappingError.new(self, id)
    end

    def to_s
      entries.map(&:to_s).join(',')
    end

    def ==(other)
      to_s == other.to_s
    end

    protected
    attr_reader :entries
  end
end
