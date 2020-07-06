require 'timeout'

module OsCtl::Lib
  module Utils::System
    include Timeout

    # @param cmd [String]
    # @param opts [Hash]
    # @option opts [Array<Integer>, :all] :valid_rcs valid exit codes
    # @option opts [Boolean] :stderr include stderr in output?
    # @option opts [Integer] :timeout in seconds
    # @option opts [Proc] :on_timeout
    # @option opts [String] :input data written to the process's stdin
    # @option opts [Hash] :env environment variables
    # @return [SystemCommandResult]
    def syscmd(cmd, opts = {})
      valid_rcs = opts[:valid_rcs] || []
      stderr = opts[:stderr].nil? ? true : opts[:stderr]

      out = ""
      log(:work, cmd)

      IO.popen(
        opts[:env] || ENV,
        "exec #{cmd} #{stderr ? '2>&1' : '2> /dev/null'}",
        opts[:input] ? 'r+' : 'r'
      ) do |io|
        if opts[:input]
          io.write(opts[:input])
          io.close_write
        end

        if opts[:timeout]
          begin
            timeout(opts[:timeout]) do
              out = io.read
            end

          rescue Timeout::Error
            if opts[:on_timeout]
              opts[:on_timeout].call(io)

            else
              Process.kill('TERM', io.pid)
              raise Exceptions::SystemCommandFailed.new(cmd, 1, '')
            end
          end

        else
          out = io.read
        end
      end

      if $?.exitstatus != 0 && (valid_rcs != :all && !valid_rcs.include?($?.exitstatus))
        raise Exceptions::SystemCommandFailed.new(cmd, $?.exitstatus, out)
      end

      SystemCommandResult.new($?.exitstatus, out)
    end

    # @param cmd [String] zfs command
    # @param opts [String] zfs options
    # @param component [String] zfs dataset
    # @param cmd_opts [Hash]
    # @option cmd_opts [Array<Integer>] :valid_rcs valid exit codes
    # @option cmd_opts [Boolean] :stderr include stderr in output?
    # @option cmd_opts [Integer] :timeout in seconds
    # @option cmd_opts [Proc] :on_timeout
    # @option cmd_opts [String] :input data written to the process's stdin
    # @option cmd_opts [Hash] :env environment variables
    # @return [SystemCommandResult]
    def zfs(cmd, opts, component, cmd_opts = {})
      syscmd("zfs #{cmd} #{opts} #{component}", cmd_opts)
    end

    # Attempt to run a block several times
    #
    # Given block is run repeatedle until it either succeeds, or the number
    # of attempts has been reached. The block is considered successful if it
    # does not raise any exceptions. {#repeat_on_failure} makes another attempt
    # at calling the block, if it raises {Exceptions::SystemCommandFailed}.
    # Any other exception will cause an immediate failure.
    #
    # @param attempts [Integer] number of attempts
    # @param wait [Integer] time to wait after a failed attempt, in seconds
    # @yield [] the block to be called
    # @return [true, any] return value
    # @return [false, Array] list of errors
    def repeat_on_failure(attempts: 3, wait: 5)
      ret = []

      attempts.times do |i|
        begin
          return [true, yield]

        rescue Exceptions::SystemCommandFailed => err
          log(:warn, "Attempt #{i+1} of #{attempts} failed for '#{err.cmd}'")
          ret << err

          break if i == attempts - 1

          sleep(wait)
        end
      end

      [false, ret]
    end
  end
end
