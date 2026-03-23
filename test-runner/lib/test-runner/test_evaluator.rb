require 'pry'
require 'osvm'
require 'rspec/expectations'
require 'test-runner/hook'
require 'test-runner/test_result'
require 'test-runner/test_script_result'
require 'test-runner/example_result'

module TestRunner
  Hook.register(:machine_class_for)
  Hook.register(:after_test_run)
  Hook.register(:after_test_script_run)

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
    def initialize(test, scripts, system: NixCli::DEFAULT_SYSTEM, test_config_path: nil, **opts)
      scripts.each do |s|
        next if s.test == test

        raise ArgumentError, "script #{s.name} is not of test #{test.path}"
      end

      @test = test
      @scripts = scripts
      @opts = opts
      @config = TestConfig.build(
        test,
        system:,
        test_config_path:,
        config_path: File.join(@opts.fetch(:state_dir), 'config.json')
      )
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

    def test_config
      @config.dig('framework', 'testConfig') || {}
    end

    # Run the test scripts
    # @yieldparam [TestScriptResult, Hash] one result per test event
    # @return [Hash<String, TestScriptResult>] script name => result
    def run
      ret = {}
      script_results = []
      test_started_at = Time.now

      do_run do
        @scripts.each do |script|
          success = false
          t1 = Time.now

          begin
            log "Running script #{script.name}"

            test_script(script.name) do |progress|
              if progress[:type] == :example
                example_result = progress[:result].to_h(
                  script: script.name,
                  progress: progress[:progress],
                  total: progress[:total]
                )

                yield(example_result) if block_given?
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

          script_result = TestScriptResult.new(script, success, t2 - t1)

          ret[script.name] = script_result
          script_results << script_result
          call_after_test_script_hook(script_result)
          yield(script_result) if block_given?
        end

        test_result = build_test_result(script_results, Time.now - test_started_at)
        call_after_test_run_hook(test_result)
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
    # Example groups can be nested. Groups are evaluated in the configured order,
    # which defaults to random.
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
    # are evaluated in the group's configured order.
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
    # RSpec expectation failures inside the block are treated as a falsey
    # return value and retried until the timeout.
    #
    # @param name [String] block name for error reporting
    # @param timeout [Integer]
    # @raise [OsVm::TimeoutError]
    # @return [any] yielded value
    def wait_for_block(name:, timeout: @default_timeout)
      t1 = Time.now
      cur_timeout = timeout

      loop do
        ret =
          begin
            yield
          rescue RSpec::Expectations::ExpectationNotMetError
            false
          end
        return ret if ret

        cur_timeout = timeout - (Time.now - t1)

        if cur_timeout <= 0
          raise OsVm::TimeoutError, "Timeout occurred while waiting for #{name}"
        end

        sleep(1)
      end
    end

    # Wait for a block that eventually succeeds
    #
    # Intended for polling code that can temporarily fail with
    # {OsVm::CommandFailed} (treated as a retry) or signal success via
    # {OsVm::CommandSucceeded}. RSpec expectation failures are also treated as
    # retryable. The method returns as soon as the block yields a truthy value
    # or raises {OsVm::CommandSucceeded}.
    #
    # @param name [String] block name for error reporting
    # @param timeout [Integer]
    # @return [any] block return value or true when success is signaled with
    #   {OsVm::CommandSucceeded}
    # @raise [OsVm::TimeoutError] when the block does not succeed in time
    def wait_until_block_succeeds(name:, timeout: @default_timeout)
      t1 = Time.now
      cur_timeout = timeout

      loop do
        ret =
          begin
            yield
          rescue OsVm::CommandFailed, RSpec::Expectations::ExpectationNotMetError
            false
          rescue OsVm::CommandSucceeded
            true
          end
        return ret if ret

        cur_timeout = timeout - (Time.now - t1)

        if cur_timeout <= 0
          raise OsVm::TimeoutError, "Timeout occurred while waiting for #{name} to succeed"
        end

        sleep(1)
      end
    end

    # Wait for a block that eventually fails
    #
    # Intended for polling code that is expected to start failing with
    # {OsVm::CommandFailed}. {OsVm::CommandSucceeded} is treated as a retryable
    # result, because the block may succeed before it starts failing. If no
    # exception is raised, the method returns once the block yields a falsey
    # value. RSpec expectations are not handled here because they cannot be
    # reliably distinguished.
    #
    # @param name [String] block name for error reporting
    # @param timeout [Integer]
    # @return [any] block return value or true when failure is signaled with
    #   {OsVm::CommandFailed}
    # @raise [OsVm::TimeoutError] when the block does not fail in time
    def wait_until_block_fails(name:, timeout: @default_timeout)
      t1 = Time.now
      cur_timeout = timeout

      loop do
        begin
          ret = yield
        rescue OsVm::CommandFailed
          return true
        rescue OsVm::CommandSucceeded
          ret = true
        end

        return ret unless ret

        cur_timeout = timeout - (Time.now - t1)

        if cur_timeout <= 0
          raise OsVm::TimeoutError, "Timeout occurred while waiting for #{name} to fail"
        end

        sleep(1)
      end
    end

    protected

    def call_after_test_run_hook(test_result)
      Hook.call(
        :after_test_run,
        kwargs: {
          test: @test,
          test_result:,
          scripts: @scripts,
          machines:,
          state_dir: @opts[:state_dir]
        }
      )
    end

    def call_after_test_script_hook(script_result)
      Hook.call(
        :after_test_script_run,
        kwargs: {
          test: @test,
          script: script_result.test_script,
          script_result:,
          machines:,
          state_dir: @opts[:state_dir]
        }
      )
    end

    def build_test_result(script_results, elapsed_time)
      test_success = script_results.all?(&:expected_result?)

      TestResult.new(
        @test,
        script_results,
        test_success,
        elapsed_time,
        @opts[:state_dir]
      )
    end

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

      results = ExampleOrdering.sort_by_order(@example_groups, @example_config.default_order).map do |grp|
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
      klass = Hook.call(:machine_class_for, args: [config])
      return klass if klass

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
