require 'pry'
require 'osvm'

module TestRunner
  class TestEvaluator
    # @return [Hash<String, OsVm::Machine>]
    attr_reader :machines

    # @param test [Test]
    # @param scripts [Array<TestScript>]
    # @param opts [Hash]
    # @option opts [Integer] :default_timeout
    # @option opts [Boolean] :destructive
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

      config['machines'].each do |name, cfg|
        var = :"@#{name}"
        m = OsVm::Machine.new(
          name,
          OsVm::MachineConfig.new(cfg),
          opts[:state_dir],
          opts[:sock_dir],
          default_timeout: opts[:default_timeout],
          hash_base: test.path
        )
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
        scripts.each do |script|
          success = false
          t1 = Time.now

          begin
            warn "Running script #{script.name}"
            test_script(script.name)
            warn "Script #{script.name} finished"
          rescue Exception => e # rubocop:disable Lint/RescueException
            warn "Exception occurred while running script #{script.name}"
            warn e.full_message
          else
            success = true
          end

          result = {
            script: script.name,
            success:,
            elapsed_time: Time.now - t1
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
    # @return [any] yielded value
    def wait_for_block(name:, timeout: @default_timeout)
      t1 = Time.now
      cur_timeout = timeout

      loop do
        ret = yield
        return ret if ret

        cur_timeout = timeout - (Time.now - t1)

        if cur_timeout <= 0
          raise TimeoutError, "Timeout occurred while waiting for #{name}"
        end

        sleep(1)
      end
    end

    protected

    attr_reader :test, :scripts, :config, :opts

    def test_script(name)
      binding.eval(config['testScripts'][name]['script']) # rubocop:disable Security/Eval
    end

    def do_run
      yield

      machines.each_value do |m|
        m.stop if m.running?
      end
    ensure
      machines.each_value do |m|
        m.kill
        m.destroy if opts[:destructive]
        m.finalize
        m.cleanup
      end
    end
  end
end
