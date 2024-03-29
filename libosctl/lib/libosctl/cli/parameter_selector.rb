module OsCtl::Lib
  # Process output parameters for CLI options -o, --output and -L
  class Cli::ParameterSelector
    # @param all_params [Array<Symbol>] list of all possible parameters
    # @param default_params [Array<Symbol>, nil] list of default parameters
    # @param allow_user_attributes [Boolean] allow custom user attributes, i.e. <vendor>:<key>
    def initialize(all_params:, default_params: nil, allow_user_attributes: true)
      @all_params = all_params.map(&:to_sym)
      @default_params = default_params ? default_params.map(&:to_sym) : @all_params
      @allow_user_attributes = allow_user_attributes
    end

    # Parse input from CLI option and return a list of wanted parameters
    # @param option [String, nil] comma-separated list of output parameters
    # @param default_params [Array<Symbol>, nil] list of default parameters
    # @raise [GLI::BadCommandLine]
    # @return [Array<Symbol>]
    def parse_option(option, default_params: nil)
      default_params ||= @default_params
      return default_params if option.nil?

      stripped = option.strip
      return [] if stripped.empty?

      wanted = stripped.split(',').map(&:to_sym)

      if wanted.length == 1 && wanted.first == :all
        return @all_params
      end

      if wanted.any?
        if wanted.first.start_with?('+')
          wanted[0] = wanted[0][1..].to_sym
          wanted = default_params + wanted
        elsif wanted.first.start_with?('-')
          wanted[0] = wanted[0][1..].to_sym
          wanted = default_params - wanted
        end
      end

      wanted.each do |param|
        if !@all_params.include?(param) \
           && (!@allow_user_attributes || !param.to_s.include?(':'))
          raise GLI::BadCommandLine, "unknown output parameter #{param.to_s.inspect}"
        end
      end

      wanted
    end

    def to_s
      @all_params.join("\n")
    end
  end
end
