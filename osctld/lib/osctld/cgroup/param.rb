module OsCtld
  module CGroup
    Param = Struct.new(:subsystem, :name, :value, :persistent) do
      # Load from config
      def self.load(hash)
        new(hash['subsystem'], hash['name'], hash['value'], true)
      end

      # Load from client
      def self.import(hash)
        new(
          hash[:subsystem],
          hash[:parameter],
          hash[:value],
          hash.has_key?(:persistent) ? hash[:persistent] : true
        )
      end

      # Dump to config
      def dump
        Hash[to_h.map { |k,v| [k.to_s, v] }]
      end

      # Export to client
      def export
        {
          subsystem: subsystem,
          parameter: name,
          value: value,
          persistent: persistent ? true : false,
        }
      end
    end
  end
end
