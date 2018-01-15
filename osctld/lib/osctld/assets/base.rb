module OsCtld
  class Assets::Base
    def self.register(type)
      @type = type
      Assets.register(type, self)
    end

    def self.type
      @type
    end

    attr_reader :path, :opts, :errors

    # @param path [String]
    # @param opts [Hash] asset-specific options
    # @option opts [String] desc description
    def initialize(path, opts, &block)
      @path = path
      @opts = opts
      @validators = []
      @errors = []

      block.call(self) if block
    end

    def type
      self.class.type
    end

    def validate(&block)
      @validators << block
    end

    def valid?
      @validators.each do |validator|
        validator.call(self)
      end

      errors.empty?
    end

    protected
    def add_error(error)
      @errors << error
    end
  end
end
