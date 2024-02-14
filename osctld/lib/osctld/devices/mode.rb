module OsCtld
  class Devices::Mode
    # @param str [String] mode as string, e.g. `rwm`, `r`, rw`
    # @return [Array<String>]
    def self.normalize(str)
      mode = str.split('')
      mode.sort!
      mode.uniq!
      mode
    end

    # @return [Array<String>]
    attr_reader :mode

    # @param str [String] mode as string, e.g. `rwm`, `r`, rw`
    def initialize(str)
      @mode = self.class.normalize(str)
    end

    # Return `true` if self is a superset of `other` or equal to `other`
    # @param other [Mode]
    def compatible?(other)
      return true if other.mode == mode

      other.mode.each do |m|
        return false unless mode.include?(m)
      end

      true
    end

    # Expand access mode with modes from `other` that are missing in self
    # @param other [Mode]
    def complement(other)
      @mode = (@mode + other.mode).sort!
      @mode.uniq!
    end

    # Generate diff to reach the `target` mode from the current mode
    #
    # The return value is a hash describing actions that need to be taken
    # to update cgroups. The hash has two keys: `:allow` and `:deny`, each
    # pointing to a mode that has to be allowed/denied.
    #
    # For example, for transition from `rm` to `wm`, the return value would be:
    #
    #   {allow: 'w', deny: 'r'}
    #
    # @param target [Mode] target mode
    # @return [Hash<Symbol, String>]
    def diff(target)
      ret = { allow: [], deny: [] }

      %w[r w m].each do |m|
        if target.mode.include?(m) && !mode.include?(m)
          ret[:allow] << m

        elsif !target.mode.include?(m) && mode.include?(m)
          ret[:deny] << m
        end
      end

      ret.transform_values(&:join)
    end

    def to_s
      %w[r w m].select { |m| mode.include?(m) }.join
    end

    def clone
      self.class.new(to_s)
    end

    def ==(other)
      other.mode == mode
    end

    {
      read: 'r',
      write: 'w',
      create: 'm'
    }.each do |k, v|
      define_method(:"can_#{k}?") { mode.include?(v) }
    end
  end
end
