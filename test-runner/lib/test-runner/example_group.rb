module TestRunner
  class ExampleGroup
    # @return [Array<ExampleGroup>]
    attr_reader :groups

    # @return [Array<Example>]
    attr_reader :examples

    # @param obj [#to_s]
    # @param parent [ExampleGroup]
    def initialize(obj, parent: nil, &block)
      @obj = obj
      @parent = parent
      @block = block
      @groups = []
      @examples = []
      @before = { context: [], example: [] }
      @after = { context: [], example: [] }
    end

    def load
      @block.call
      @block = nil
    end

    # @return [String]
    def message
      ret = [@obj.to_s]
      ret << @parent.message if @parent
      ret.reverse.join(' ')
    end

    # @param group [ExampleGroup]
    def add_group(group)
      @groups << group
    end

    # @param example [Example]
    def add_example(example)
      @examples << example
    end

    # @param type [:context, :example]
    # @param block [Proc]
    def add_before(type, block)
      @before[type] << block
    end

    # @param type [:context, :example]
    # @param block [Proc]
    def add_after(type, block)
      @after[type] << block
    end

    # @yieldparam [Example] evaluated example
    # @return [Array<ExampleResult>]
    def evaluate(&block)
      results = []

      @before[:context].each(&:call)

      examples.shuffle.each do |example|
        @before[:example].each(&:call)
        block.call(example) if block
        results << example.evaluate
        @after[:example].each(&:call)
      end

      groups.shuffle.each do |grp|
        results.concat(grp.evaluate(&block))
      end

      @after[:context].each(&:call)

      results
    end
  end
end
