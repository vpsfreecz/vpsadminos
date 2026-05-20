# frozen_string_literal: true

module TestRunner::Cli
  class FilterExpression
    def initialize(str_filter)
      @source = str_filter.to_s
      @tokens = tokenize(@source)
      @pos = 0

      error('empty expression') if @tokens.empty?

      @expr = parse_or
      error("unexpected token #{peek[1].inspect}") if peek
    end

    # @param test_script [TestRunner::TestScript]
    def pass?(test_script)
      @expr.call(test_script)
    end

    protected

    attr_reader :source

    def tokenize(str)
      tokens = []
      i = 0

      while i < str.length
        c = str[i]

        if c.match?(/\s/)
          i += 1
        elsif str[i, 2] == '&&'
          tokens << [:and, '&&']
          i += 2
        elsif str[i, 2] == '||'
          tokens << [:or, '||']
          i += 2
        elsif str[i, 2] == '!='
          tokens << [:neq, '!=']
          i += 2
        elsif c == '='
          tokens << [:eq, '=']
          i += 1
        elsif c == '('
          tokens << [:lparen, '(']
          i += 1
        elsif c == ')'
          tokens << [:rparen, ')']
          i += 1
        elsif ['&', '|', '!'].include?(c)
          error("unexpected token #{c.inspect}")
        else
          j = i
          j += 1 while j < str.length && str[j] !~ /[\s()&|!=]/
          tokens << [:word, str[i...j]]
          i = j
        end
      end

      tokens
    end

    def parse_or
      expr = parse_and

      while accept(:or)
        left = expr
        right = parse_and
        expr = or_expr(left, right)
      end

      expr
    end

    def parse_and
      expr = parse_factor

      while accept(:and)
        left = expr
        right = parse_factor
        expr = and_expr(left, right)
      end

      expr
    end

    def parse_factor
      if accept(:lparen)
        expr = parse_or
        expect(:rparen)
        expr
      else
        parse_comparison
      end
    end

    def parse_comparison
      key = expect(:word)[1]
      op = accept(:eq) || accept(:neq)
      error('expected = or !=') unless op
      value = expect(:word)[1]

      proc do |test_script|
        if key == 'tag'
          test_script.tags.include?(value) == (op[0] == :eq)
        elsif op[0] == :eq
          test_script.labels[key].to_s == value
        else
          test_script.labels[key].to_s != value
        end
      end
    end

    def or_expr(left, right)
      proc { |test_script| left.call(test_script) || right.call(test_script) }
    end

    def and_expr(left, right)
      proc { |test_script| left.call(test_script) && right.call(test_script) }
    end

    def accept(type)
      token = peek
      return unless token && token[0] == type

      @pos += 1
      token
    end

    def expect(type)
      token = accept(type)
      return token if token

      expected = {
        word: 'identifier',
        rparen: ')'
      }.fetch(type, type.to_s)

      error("expected #{expected}")
    end

    def peek
      @tokens[@pos]
    end

    def error(message)
      raise GLI::BadCommandLine, "Invalid filter expression #{source.inspect}: #{message}"
    end
  end
end
