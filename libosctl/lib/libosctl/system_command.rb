require 'shellwords'
require 'libosctl/exceptions'
require 'libosctl/system_command_result'

module OsCtl::Lib
  # Run an external command to an absolute deadline. Only spawn/exec crosses
  # the process boundary; daemon objects and their locks stay in the caller.
  class SystemCommand
    def initialize(argv, deadline:, env: ENV, input: nil, stderr: true, valid_rcs: [])
      @argv = argv
      @deadline = deadline
      @env = env
      @input = (input || '').b
      @stderr = stderr
      @valid_rcs = valid_rcs
    end

    def run
      time_left
      input_r, input_w = IO.pipe
      output_r, output_w = IO.pipe
      pid = Process.spawn(@env, *@argv, in: input_r, out: output_w, err: @stderr ? output_w : File::NULL)
      input_r.close
      output_w.close
      output = communicate(input_w, output_r)

      loop do
        exited = Process.wait2(pid, Process::WNOHANG)
        if exited
          status = exited.last
          pid = nil
          rc = status.exitstatus || (128 + status.termsig)
          unless rc == 0 || @valid_rcs == :all || @valid_rcs.include?(rc)
            raise Exceptions::SystemCommandFailed.new(@argv.shelljoin, rc, output)
          end

          return SystemCommandResult.new(rc, output)
        end

        sleep([time_left, 0.05].min)
      end
    ensure
      [input_r, input_w, output_r, output_w].compact.each { |io| io.close unless io.closed? }
      terminate(pid) if pid
    end

    protected

    def communicate(input, output)
      pending = @input
      result = +''
      eof = false
      input.close if pending.empty?

      until eof && pending.empty?
        readable, writable = IO.select(eof ? [] : [output], pending.empty? ? [] : [input], nil, time_left)
        next unless readable

        if readable.include?(output)
          chunk = output.read_nonblock(16_384, exception: false)
          if chunk.nil?
            eof = true
          elsif chunk != :wait_readable
            result << chunk
          end
        end

        next unless writable.include?(input)

        count = input.write_nonblock(pending.byteslice(0, 16_384), exception: false)
        next if count == :wait_writable

        pending = pending.byteslice(count..)
        input.close if pending.empty?
      end
      result
    end

    def time_left
      remaining = @deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
      raise Exceptions::SystemCommandTimeout, @argv.shelljoin unless remaining > 0

      remaining
    end

    def terminate(pid)
      return if Process.waitpid(pid, Process::WNOHANG)

      Process.kill('KILL', pid)
      # Do not block on an uninterruptible command after its deadline.
      Process.detach(pid)
    rescue Errno::ECHILD
      nil
    end
  end
end
