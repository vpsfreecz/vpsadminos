module OsCtld
  class Assets::Base
    def self.register(type)
      @type = type
      Assets.register(type, self)
    end

    class << self
      attr_reader :type
    end

    attr_reader :path, :opts, :errors

    # @param path [String]
    # @param opts [Hash] asset-specific options
    # @option opts [String] desc description
    # @option opts [Proc] validate_if
    def initialize(path, opts, &block)
      @path = path
      @opts = opts
      @block_validators = []
      @errors = []
      @valid = nil
      @state = nil

      block.call(self) if block
    end

    def type
      self.class.type
    end

    # Return a list of datasets and a list properties needed for validation
    # @return [Array< Array<String>, Array<String> >]
    def prefetch_zfs
      [[], []]
    end

    def validate?
      if @opts.has_key?(:validate_if)
        if @opts[:validate_if].is_a?(Proc)
          @opts[:validate_if].call
        else
          @opts[:validate_if]
        end
      else
        true
      end
    end

    def validate_block(&block)
      @block_validators << block
    end

    def valid?
      if @valid.nil?
        raise 'asset not validated'
      elsif !validate?
        raise 'asset cannot be validated'
      end

      @valid
    end

    # @return [:valid, :invalid, :unknown]
    def state
      raise 'asset not validated' if @state.nil?

      @state
    end

    def add_error(error)
      @errors << error
    end

    protected

    # @param run [Assets::Validator::Run]
    def run_validation(run)
      @valid = nil
      @state = nil
      @errors = []

      unless validate?
        @state = :unknown
        return
      end

      validate(run)

      @block_validators.each do |block_validator|
        block_validator.call(self, run)
      end

      @valid = errors.empty?
      @state = @valid ? :valid : :invalid
    end

    # Implement in subclasses to validate the asset
    # @param run [Assets::Validator::Run]
    def validate(run); end
  end
end
