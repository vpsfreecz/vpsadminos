module VpsAdminOS::Converter
  # Represents a config file for OpenVZ Legacy container
  class Vz6::Config
    def self.parse(ctid, path)
      f = File.open(path, 'r')
      c = new(ctid, f)
      f.close
      c
    end

    attr_reader :ctid

    def initialize(ctid, io)
      @ctid = ctid
      @items = {}

      parse(io)
    end

    # yield [Vz6::ConfigItem]
    def each(&)
      @items.each_value(&)
    end

    # @param k [String] config key
    # @return [Vz6::ConfigItem]
    def [](k)
      @items[k]
    end

    def consume(k)
      it = @items[k]
      return unless it

      it.consume
      it.value
    end

    protected

    def parse(io)
      io.each_line do |line|
        raw_line = line
        line = line.strip

        case line
        when /\A#/, /\A\z/
          next

        when /\A([A-Z_]+)="([^"]*)"\z/, /\A([A-Z_]+)=([^\s]+)\z/
          item = Vz6::ConfigItem.new(ctid, ::Regexp.last_match(1), ::Regexp.last_match(2))
          @items[item.key] = item

        else
          warn "Unknown line '#{raw_line}'"
        end
      end
    end
  end
end
