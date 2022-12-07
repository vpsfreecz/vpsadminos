module OsCtl::Lib
  # {IdMap} represents ID mappings for user namespaces, be it user or group IDs
  class IdMap
    Entry = Struct.new(:ns_id, :host_id, :count) do
      def self.from_string(str, separator: ':')
        ns_id, host_id, cnt = str.split(separator)
        Entry.new(ns_id.to_i, host_id.to_i, cnt.to_i)
      end

      def self.from_hash(hash)
        Entry.new(hash[:ns_id], hash[:host_id], hash[:count])
      end

      def to_a
        [ns_id, host_id, count]
      end

      def to_s
        "#{ns_id}:#{host_id}:#{count}"
      end
    end

    # @param list [Array<String>]
    # @return [IdMap]
    def self.from_string_list(list, **opts)
      new(list.map { |str| Entry.from_string(str, **opts) })
    end

    # @param list [Array<Hash>]
    # @return [IdMap]
    def self.from_hash_list(list)
      new(list.map { |hash| Entry.from_hash(hash) })
    end

    # @param entries [Array<Entry>]
    def initialize(entries = [])
      @entries = entries.clone
    end

    def valid?
      return false if ns_to_host(0) < 0

      entries.each do |e|
        return false if e.ns_id < 0 || e.host_id < 0 || e.count < 1
      end

      true

    rescue Exceptions::IdMappingError
      false
    end

    def add_from_string(str_entry, **opts)
      @entries << Entry.from_string(str_entry, **opts)
    end

    def add_from_hash(hash)
      @entries << Entry.from_hash(hash)
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

      raise Exceptions::IdMappingError.new(self, id)
    end

    # Map ID from the host to the namespace
    def host_to_ns(id)
      entries.each do |e|
        if id >= e.host_id && id < (e.host_id + e.count)
          return (id - e.host_id) + e.ns_id
        end
      end

      raise Exceptions::IdMappingError.new(self, id)
    end

    def include_host_id?(id)
      entries.each do |e|
        return true if id >= e.host_id && id < (e.host_id + e.count)
      end

      false
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
