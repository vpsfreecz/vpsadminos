require 'libosctl'

module OsCtl::Cli
  class Ps::Filter
    OPERANDS = %w[=~ !~ != >= <= = > <].freeze

    NUMERIC = %i[
      pid
      ctpid
      ruid
      rgid
      euid
      egid
      ctruid
      ctrgid
      cteuid
      ctegid
    ].freeze

    BYTES = %i[
      vmsize
      rss
    ].freeze

    TIMES = %i[
      start
      time
    ].freeze

    STRINGS = %i[
      pool
      ctid
      state
      command
      name
    ].freeze

    ALL_PARAMS = NUMERIC + BYTES + TIMES + STRINGS

    include OsCtl::Lib::Utils::Humanize

    # @param str_rule [String] condition written as string
    def initialize(str_rule)
      @parameter, @op, @value = parse_rule(str_rule)
    end

    # @param process [OsCtl::Lib::OsProcess]
    # @return [Boolean]
    def match?(process)
      param = get_param(process, @parameter)

      if @op == :=~
        @value.match?(param)
      elsif @op == :!~
        !@value.match?(param)
      else
        param.send(@op, @value)
      end
    end

    protected

    def parse_rule(str_rule)
      ret_param, ret_op, ret_value = nil

      OPERANDS.detect do |op|
        i = str_rule.index(op)
        next if i.nil?

        ret_param = str_rule[0..(i - 1)].to_sym

        unless ALL_PARAMS.include?(ret_param)
          raise ArgumentError, "invalid parameter #{ret_param.to_s.inspect}"
        end

        is_string = STRINGS.include?(ret_param)
        is_num = NUMERIC.include?(ret_param)
        is_data = !is_string && !is_num && BYTES.include?(ret_param)
        is_time = !is_string && !is_num && !is_data && TIMES.include?(ret_param)
        ret_op = op == '=' ? :== : op.to_sym

        if !is_string && %i[=~ !~].include?(ret_op)
          raise ArgumentError, "invalid parameter filter #{str_rule.inspect}: #{ret_op} cannot be used on numbers"
        end

        value = str_rule[(i + op.size)..-1]
        ret_value =
          if is_num
            value.to_i
          elsif is_data
            parse_data(value)
          elsif is_time
            value.to_i
          elsif %i[=~ !~].include?(ret_op)
            Regexp.new(value)
          else
            value
          end
      end

      if ret_op.nil?
        raise ArgumentError, "invalid parameter filter #{str_rule.inspect}: unknown operand"
      end

      [ret_param, ret_op, ret_value]
    end

    def get_param(process, param)
      case param
      when :command
        v = process.cmdline
        v.empty? ? process.name : v

      when :start
        process.start_time.to_i

      when :time
        process.user_time + process.sys_time

      else
        process.send(param)
      end
    end
  end
end
