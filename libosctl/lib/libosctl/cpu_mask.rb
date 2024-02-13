require 'etc'

module OsCtl::Lib
  # Interface for CPU masks
  class CpuMask
    # @param mask [Array<Integer>]
    # @return [String]
    def self.format(mask)
      new(mask).to_s
    end

    # @param mask [String, Array<Integer>]
    def initialize(mask)
      @cpu_list =
        if mask.is_a?(String)
          parse_cpus(mask)
        elsif mask.is_a?(Array)
          mask
        else
          raise ArgumentError, 'mask can be either a string or a list of integers'
        end
    end

    # Check if the mask includes a particular CPU
    # @param cpu [Integer]
    # @return [Boolean]
    def include?(cpu)
      if @cpu_list == :all
        true
      else
        @cpu_list.include?(cpu)
      end
    end

    # Return an intersection of self with other mask as a new mask
    # @param other [CpuMask]
    # @return [CpuMask]
    def &(other)
      self.class.new(to_a & other.to_a)
    end

    # Return the number of CPUs
    # @return [Integer]
    def size
      if @cpu_list == :all
        all_range.size
      else
        @cpu_list.size
      end
    end

    # @yieldparam cpu [Integer]
    def each(&)
      if @cpu_list == :all
        all_range.each(&)
      else
        @cpu_list.each(&)
      end
    end

    # Return CPUs as an array
    # @return [Array<Integer>]
    def to_a
      if @cpu_list == :all
        all_range.to_a
      else
        @cpu_list
      end
    end

    # @return [String]
    def to_s
      @string ||= format(@cpu_list == :all ? all_range : @cpu_list)
    end

    protected

    def parse_cpus(str)
      return :all if str == '*'

      ret = []

      str.split(',').each do |grp|
        sep = grp.index('-')

        if sep
          parts = grp.split('-')

          if parts.length != 2
            raise ArgumentError, "invalid cpu mask #{str.inspect}"
          end

          first, last = parts
          ret.concat((first.to_i..last.to_i).to_a)
        else
          ret << grp.to_i
        end
      end

      ret.sort!
      ret
    end

    def all_range
      @all_range ||= (0..(Etc.nprocessors - 1))
    end

    def format(cpu_list)
      return if cpu_list.empty?

      groups = []
      acc = []
      prev = nil

      cpu_list.each do |cpu|
        if prev.nil? || cpu == prev + 1
          prev = cpu
          acc << cpu
        else
          groups << format_range(acc)
          prev = nil
          acc = [cpu]
        end
      end

      groups << format_range(acc)
      groups.join(',')
    end

    def format_range(acc)
      len = acc.length

      if len == 1
        acc.first
      elsif len == 2
        acc.join(',')
      elsif len > 2
        "#{acc.first}-#{acc.last}"
      end
    end
  end
end
