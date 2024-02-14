module OsCtld
  class Devices::Device
    # Load from config
    def self.load(hash)
      major = hash['major'].to_s
      minor = hash['minor'].to_s
      new(
        hash['type'].to_sym,
        major == 'all' ? '*' : major,
        minor == 'all' ? '*' : minor,
        hash['mode'],
        name: hash['name'],
        inherit: hash['inherit']
      )
    end

    # Load from client
    def self.import(hash)
      new(
        hash[:type].to_sym,
        hash[:major].to_s,
        hash[:minor].to_s,
        hash[:mode],
        name: hash[:dev_name],
        inherit: hash[:inherit]
      )
    end

    attr_reader :type, :major, :minor, :mode, :name
    attr_writer :inherited, :inherit

    # @param type [:char, :block]
    # @param major [Integer, Symbol]
    # @param minor [Integer, Symbol]
    # @param mode [String]
    # @param opts [Hash]
    # @option opts [String] :name
    # @option opts [Boolean] :inherit should the child groups/containers
    #                                 inherit this device?
    # @option opts [Boolean] :inherited was this device inherited from the
    #                                   parent group?
    def initialize(type, major, minor, mode, **opts)
      @type = type
      @major = major
      @minor = minor
      @mode = Devices::Mode.new(mode)
      @name = opts[:name]
      @inherit = opts.has_key?(:inherit) ? opts[:inherit] : true
      @inherited = opts.has_key?(:inherited) ? opts[:inherited] : false
    end

    def inherit?
      @inherit
    end

    def inherited?
      @inherited
    end

    def promoted?
      !@inherited
    end

    # @param m [Devices::Mode]
    def mode=(m)
      @mode = Devices::Mode.new(m.to_s)
    end

    # Change mode and return action for cgroup update
    #
    # The return value is a hash describing actions that need to be taken
    # to update cgroups. The hash can have two keys: `:allow` and `:deny`, each
    # pointing to a value that has to be written to `devices.allow` or
    # `devices.deny`, depending on the action type.
    #
    # For example, for transition from `rm` to `wm`, the return value would be:
    #
    #   {allow: 'c 1:5 w', deny: 'c 1:5 r'}
    #
    # @param new_mode [Devices::Mode]
    # @return [Hash<Symbol, String>]
    def chmod(new_mode)
      diff = mode.diff(new_mode)
      self.mode = new_mode
      diff.reject { |_k, v| v.empty? }.to_h { |k, v| [k, to_s(mode: v)] }
    end

    # Dump to config
    def dump
      export.transform_keys(&:to_s)
    end

    # Export to client
    def export
      {
        type: type.to_s,
        major:,
        minor:,
        mode: mode.to_s,
        name:,
        inherit: inherit?,
        inherited: inherited?
      }
    end

    def type_s
      case type
      when :char
        'c'
      when :block
        'b'
      else
        raise "invalid device type '#{type}'"
      end
    end

    # @param opts [Hash]
    # @option opts [Devices::Mode, String] :mode
    def to_s(opts = {})
      "#{type_s} #{major}:#{minor} #{opts[:mode] || mode || 'rwm'}"
    end

    def ==(other)
      type == other.type && major == other.major && minor == other.minor
    end

    %i[read write create].each do |v|
      m = :"can_#{v}?"
      define_method(m) { mode.send(m) }
    end
  end
end
