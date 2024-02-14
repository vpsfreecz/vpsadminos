module OsCtld
  module CGroup
    Param = Struct.new(:version, :subsystem, :name, :value, :persistent) do
      # Load from config
      def self.load(hash)
        new(
          hash.fetch('version', 1),
          hash['subsystem'],
          hash['name'],
          hash['value'],
          true
        )
      end

      # Load from client
      def self.import(hash)
        new(
          hash.fetch(:version, CGroup.version),
          hash[:subsystem],
          hash[:parameter],
          hash[:value],
          hash.has_key?(:persistent) ? hash[:persistent] : true
        )
      end

      # Dump to config
      def dump
        to_h.to_h { |k, v| [k.to_s, v] }
      end

      # Export to client
      def export
        {
          version:,
          subsystem:,
          parameter: name,
          value:,
          persistent: persistent ? true : false
        }
      end
    end
  end
end
