require 'open3'
require 'shellwords'
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

      out = ''
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

      if $?.exitstatus != 0 && valid_rcs != :all && !valid_rcs.include?($?.exitstatus)
        raise Exceptions::SystemCommandFailed.new(cmd, $?.exitstatus, out)
      end

      SystemCommandResult.new($?.exitstatus, out)
    end

    # Run a command without a shell.
    #
    # @param argv [Array<String>] command and arguments
    # @param opts [Hash]
    # @option opts [Array<Integer>, :all] :valid_rcs valid exit codes
    # @option opts [Boolean] :stderr include stderr in output?
    # @option opts [Integer] :timeout in seconds
    # @option opts [Proc] :on_timeout
    # @option opts [String] :input data written to the process's stdin
    # @option opts [Hash] :env environment variables
    # @return [SystemCommandResult]
    def syscmd_argv(argv, opts = {})
      valid_rcs = opts[:valid_rcs] || []
      stderr = opts[:stderr].nil? ? true : opts[:stderr]
      cmd = argv.shelljoin
      out = ''
      status = nil

      log(:work, cmd)

      if stderr
        Open3.popen2e(opts[:env] || ENV, *argv) do |stdin, stdout_err, wait_thr|
          write_stdin(stdin, opts[:input])
          out = read_process_output(stdout_err, wait_thr, cmd, opts)
          status = wait_thr.value
        end
      else
        Open3.popen2(opts[:env] || ENV, *argv, err: File::NULL) do |stdin, stdout, wait_thr|
          write_stdin(stdin, opts[:input])
          out = read_process_output(stdout, wait_thr, cmd, opts)
          status = wait_thr.value
        end
      end

      if status.exitstatus != 0 && valid_rcs != :all && !valid_rcs.include?(status.exitstatus)
        raise Exceptions::SystemCommandFailed.new(cmd, status.exitstatus, out)
      end

      SystemCommandResult.new(status.exitstatus, out)
    end

    def find_executable!(cmd)
      ENV.fetch('PATH', '').split(File::PATH_SEPARATOR).each do |dir|
        path = File.join(dir, cmd)
        next unless File.file?(path) && File.executable?(path)

        return File.realpath(path)
      end

      raise Errno::ENOENT, cmd
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
        return [true, yield]
      rescue Exceptions::SystemCommandFailed => e
        log(:warn, "Attempt #{i + 1} of #{attempts} failed for '#{e.cmd}'")
        ret << e

        break if i == attempts - 1

        sleep(wait)
      end

      [false, ret]
    end

    protected

    def write_stdin(io, input)
      io.write(input) if input
      io.close
    end

    def read_process_output(io, wait_thr, cmd, opts)
      if opts[:timeout]
        begin
          timeout(opts[:timeout]) { io.read }
        rescue Timeout::Error
          if opts[:on_timeout]
            opts[:on_timeout].call(wait_thr)
            ''
          else
            Process.kill('TERM', wait_thr.pid)
            raise Exceptions::SystemCommandFailed.new(cmd, 1, '')
          end
        end
      else
        io.read
      end
    end
  end
end
