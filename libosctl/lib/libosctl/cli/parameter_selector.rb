module OsCtl::Lib
  # Process output parameters for CLI options -o, --output and -L
  class Cli::ParameterSelector
    # @param all_params [Array<Symbol>] list of all possible parameters
    # @param default_params [Array<Symbol>, nil] list of default parameters
    def initialize(all_params:, default_params: nil)
      @all_params = all_params.map(&:to_sym)
      @default_params = default_params ? default_params.map(&:to_sym) : @all_params
    end

    # Parse input from CLI option and return a list of wanted parameters
    # @param option [String, nil] comma-separated list of output parameters
    # @raise [GLI::BadCommandLine]
    # @return [Array<Symbol>]
    def parse_option(option)
      return @default_params if option.nil?

      stripped = option.strip
      return [] if stripped.empty?

      wanted = stripped.split(',').map(&:to_sym)

      if wanted.length == 1 && wanted.first == :all
        return @all_params
      end

      wanted.each do |param|
        unless @all_params.include?(param)
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
