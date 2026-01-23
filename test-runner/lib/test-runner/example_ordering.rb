module TestRunner
  module ExampleOrdering
    module_function

    # Sort an array according to the given order
    # @param array [Array]
    # @param order [:defined, :rand, Random, Integer]
    def sort_by_order(array, order)
      case order
      when :defined
        array
      when :rand
        array.shuffle
      when Random
        array.shuffle(random: order)
      when Integer
        array.shuffle(random: Random.new(order))
      else
        raise "Invalid order #{order.inspect}"
      end
    end
  end
end
