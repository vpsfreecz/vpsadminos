module VpsAdminOS::Converter
  class Devices < Array
    class Device
      attr_accessor :type, :major, :minor, :mode, :name, :inherit

      # @param type [String]
      # @param major [String]
      # @param minor [String]
      # @param mode [String]
      # @param opts [Hash]
      # @option opts [String] :name device node name
      # @option opts [Boolean] :inherit
      def initialize(type, major, minor, mode, opts = {})
        @type = type
        @major = major
        @minor = minor
        @mode = mode
        @name = opts[:name]
        @inherit = opts.has_key?(:inherit) ? opts[:inherit] : true
      end

      def dump
        {
          'type' => type,
          'major' => major,
          'minor' => minor,
          'mode' => mode,
          'name' => name,
          'inherit' => inherit,
        }
      end
    end

    def dump
      map(&:dump)
    end
  end
end
