require 'pry'
require 'osvm'
require 'rspec/expectations'

module TestRunner
  class TestEvaluator
    include RSpec::Matchers

    # @return [Hash<String, OsVm::Machine>]
    attr_reader :machines

    # @param test [Test]
    # @param scripts [Array<TestScript>]
    # @param opts [Hash]
    # @option opts [Integer] :default_timeout
    # @option opts [Boolean] :destructive
    # @option opts [Boolean] :recreate_disks
    # @option opts [String] :state_dir
    # @option opts [String] :sock_dir
    def initialize(test, scripts, **opts)
      scripts.each do |s|
        next if s.test == test

        raise ArgumentError, "script #{s.name} is not of test #{test.path}"
      end

      @test = test
      @scripts = scripts
      @config = TestConfig.build(test)
      @opts = opts
      @machines = {}
      @default_timeout = opts.fetch(:default_timeout)
      @used_container_ids = []

      @config['machines'].each do |name, cfg|
        var = :"@#{name}"

        machine_config = OsVm::MachineConfig.from_config(cfg)

        m = machine_class_for(machine_config).new(
          name,
          machine_config,
          opts[:state_dir],
          opts[:sock_dir],
          default_timeout: opts[:default_timeout],
          hash_base: test.path
        )

        m.destroy_disks if opts[:recreate_disks]

        instance_variable_set(var, m)

        define_singleton_method(name) do
          instance_variable_get(var)
        end

        machines[name] = m
      end
    end

    # Run the test scripts
    # @yieldparam [Hash] one result per test script
    # @return [Hash<String, Boolean>] script name => result
    def run
      ret = {}

      do_run do
        @scripts.each do |script|
          success = false
          t1 = Time.now

          begin
            log "Running script #{script.name}"

            test_script(script.name) do |progress|
              if progress[:type] == :example
                yield({
                  type: :example,
                  script: script.name,
                  example: progress[:result].example.full_message,
                  progress: progress[:progress],
                  total: progress[:total],
                  success: progress[:result].success?,
                  pending: progress[:result].pending?,
                  skip: progress[:result].skip?,
                  elapsed_time: progress[:result].elapsed_time
                })
              end
            end

            t2 = Time.now
            log "Script #{script.name} finished in #{(t2 - t1).round(2)}s"
          rescue Exception => e # rubocop:disable Lint/RescueException
            t2 = Time.now
            log "Exception occurred while running script #{script.name} in #{(t2 - t1).round(2)}s"
            log e.full_message
          else
            success = true
          end

          result = {
            type: :script,
            script: script.name,
            success:,
            elapsed_time: t2 - t1
          }

          ret[script.name] = result
          yield(result) if block_given?
        end
      end

      ret
    end

    # Run interactive shell
    def interactive
      do_run do
        binding.pry # rubocop:disable Lint/Debugger
      end
    end

    # Start all machines
    def start_all
      machines.each(&:start)
    end

    # Invoke interactive shell from within a test
    def breakpoint
      binding.pry # rubocop:disable Lint/Debugger
    end

    # Configure default settings for example groups
    # @yieldparam [ExampleConfiguration]
    def configure_examples
      yield(@example_config)
    end

    # Create an example group
    #
    # Example groups can be nested. Groups are evaluated in random order.
    # Groups contain examples which are defined within the yielded block
    # using {#it}.
    #
    # @param obj [#to_s]
    # @param order [nil, :defined, :rand, Random, Integer] order in which examples and subgroups are evaluated
    def describe(obj, order: nil, &)
      grp = ExampleGroup.new(obj, parent: @group_stack.last, order:, config: @example_config, &)

      if @group_stack.any?
        @group_stack.last.add_group(grp)
      else
        @example_groups << grp
      end

      @group_stack << grp

      grp.load

      @group_stack = @group_stack[0..-2]
      nil
    end

    alias context describe

    # Code block executed before suite, context or example
    # @param type [:suite, :context, :example]
    def before(type, &block)
      if type == :suite
        @before << block
        return
      end

      raise 'Called outside of an example group, use from #describe block' if @group_stack.empty?

      @group_stack.last.add_before(type, block)
    end

    # Code block executed after suite, context or example
    # @param type [:suite, :context, :example]
    def after(type, &block)
      if type == :suite
        @after << block
        return
      end

      raise 'Called outside of an example group, use from #describe block' if @group_stack.empty?

      @group_stack.last.add_after(type, block)
    end

    # Create a test example
    #
    # {#it} must be called from within a {#describe} block. Examples within a group
    # are evaluated in random order.
    #
    # @param message [String]
    # @param pending [Boolean]
    # @param skip [Boolean]
    def example(message, pending: false, skip: false, &block)
      raise 'Called outside of an example group, use from #describe block' if @group_stack.empty?

      grp = @group_stack.last
      grp.add_example(Example.new(grp, message, pending:, skip: skip || block.nil?, &block))
      nil
    end

    alias it example

    # Create a pending example or mark the currently evaluated example as pending
    # @param message [String]
    # @param skip [Boolean]
    def pending(message = '', skip: false, &block)
      if block || @current_example.nil?
        it(message, pending: true, skip:, &block)
      else
        @current_example.send(:set_pending)
      end
    end

    # Create a skipped example or mark the currently evaluated example as pending
    # @param message [String]
    def skip(message = '', &block)
      if block || @current_example.nil?
        it(message, skip: true, &block)
      else
        @current_example.send(:set_skip)
        throw :skip
      end
    end

    # Generate container id that is unique to the test run
    # @return [String]
    def get_container_id(base = 'testct')
      10.times do
        new_id = "#{base}-#{SecureRandom.hex(2)}"

        if @used_container_ids.include?(new_id)
          sleep(0.05)
          next
        end

        @used_container_ids << new_id
        return new_id
      end

      raise 'Unable to generate unique container id'
    end

    # Wait for block to succeed
    #
    # Yield until the code block returns a truthy value or a timeout is reached.
    #
    # @param name [String] block name for error reporting
    # @param timeout [Integer]
    # @raise [OsVm::TimeoutError]
    # @return [any] yielded value
    def wait_for_block(name:, timeout: @default_timeout)
      t1 = Time.now
      cur_timeout = timeout

      loop do
        ret = yield
        return ret if ret

        cur_timeout = timeout - (Time.now - t1)

        if cur_timeout <= 0
          raise OsVm::TimeoutError, "Timeout occurred while waiting for #{name}"
        end

        sleep(1)
      end
    end

    protected

    def test_script(name, &)
      @example_config = ExampleConfiguration.new
      @before = []
      @after = []
      @example_groups = []
      @group_stack = []

      binding.eval(@config['testScripts'][name]['script']) # rubocop:disable Security/Eval

      return if @example_groups.empty?

      run_examples(&)
    end

    def run_examples
      example_count = get_example_count
      i = 1

      log 'Evaluating examples'

      @before.each(&:call)

      results = @example_groups.shuffle.map do |grp|
        grp.evaluate do |type, example_or_result|
          if type == :before
            log "[#{i}/#{example_count}] Evaluating '#{example_or_result.full_message}'"
            @current_example = example_or_result
          else
            result = example_or_result

            status =
              if result.success?
                if result.pending?
                  'pending'
                elsif result.skip?
                  'skipped'
                else
                  'succeeded'
                end
              elsif result.pending?
                'unexpectedly succeeded'
              else
                'failed'
              end

            log "[#{i}/#{example_count}] '#{result.title}' #{status} in #{result.elapsed_time.round(2)}s"

            # No block is given in debug mode
            if block_given?
              yield({ type: :example, progress: i, total: example_count, result: result })
            end

            @current_example = nil

            i += 1
          end
        end
      end.flatten

      @after.each(&:call)

      failed = results.select(&:failure?)
      return if failed.empty?

      warn "\n#{failed.count} examples failed:"

      failed.each do |result|
        warn result.title
        warn result.error
        warn "\n\n"
      end

      raise 'One or more examples failed'
    end

    def get_example_count(groups: nil)
      cnt = 0

      (groups || @example_groups).each do |grp|
        cnt += grp.examples.count(&:evaluate?)
        cnt += get_example_count(groups: grp.groups)
      end

      cnt
    end

    def log(msg)
      warn "[#{Time.now}] #{msg}"
    end

    def do_run
      yield

      machines.each_value do |m|
        m.stop if m.running? && m.can_execute?
      end
    ensure
      machines.each_value do |m|
        m.kill
        m.destroy if @opts[:destructive]
        m.finalize
        m.cleanup
      end
    end

    def machine_class_for(config)
      case config.spin
      when 'vpsadminos'
        OsVm::VpsadminosMachine
      when 'nixos'
        OsVm::NixosMachine
      else
        raise ArgumentError, "Unknown machine spin #{config.spin.inspect}"
      end
    end
  end
end
