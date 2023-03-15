module OsCtl::Lib
  module StringEscape
    # Escape path so that it can be used as a file name
    #
    # Alphanumeric characters and ";" ":" are kept as is, while all other
    # characters are replaced by C-style escape sequences.
    #
    # @param path [String]
    # @return [String]
    def self.escape_path(path)
      path = path[1..] while path.start_with?('/')
      path = '/' if path.empty?

      path.each_char.inject('') do |ret, c|
        if c == '/'
          ret << '-'
        elsif /[a-zA-Z0-9:_]/ =~ c
          ret << c
        else
          ret << "\\x" << c.ord.to_s(16)
        end

        ret
      end
    end

    # Return unescaped path as escaped by {#escape_path}
    # @param str [String]
    # @return [String]
    def self.unescape_path(str)
      ret = '/'
      return ret if str == '-'

      escape_seq = nil

      ret << str.each_char.inject('') do |acc, c|
        if c == "\\"
          acc << escape_seq if escape_seq
          escape_seq = c

        elsif escape_seq
          escape_seq << c

          if escape_seq.length == 4 # \\ x <n> <n>
            acc << escape_seq[2..3].to_i(16).chr
            escape_seq = nil
          end

        elsif c == '-'
          acc << '/'

        else
          acc << c
        end

        acc
      end

      ret << escape_seq if escape_seq
      ret
    end
  end
end
