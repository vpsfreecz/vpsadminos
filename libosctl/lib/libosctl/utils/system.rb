require 'timeout'

module OsCtl::Lib
  module Utils::System
    include Timeout

    # @param cmd [String]
    # @param opts [Hash]
    # @option opts [Array<Integer>] :valid_rcs valid exit codes
    # @option opts [Boolean] :stderr include stderr in output?
    # @option opts [Integer] :timeout in seconds
    # @option opts [Proc] :on_timeout
    # @option opts [String] :input data written to the process's stdin
    # @return [Hash]
    def syscmd(cmd, opts = {})
      valid_rcs = opts[:valid_rcs] || []
      stderr = opts[:stderr].nil? ? true : opts[:stderr]

      out = ""
      log(:work, 'general', cmd)

      IO.popen(
        "exec #{cmd} #{stderr ? '2>&1' : '2> /dev/null'}",
        opts[:input] ? 'r+' : 'r'
      ) do |io|
        io.write(opts[:input]) if opts[:input]

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
              raise Exceptions::SystemCommandFailed, "Command '#{cmd}' failed: timeout"
            end
          end

        else
          out = io.read
        end
      end

      if $?.exitstatus != 0 && !valid_rcs.include?($?.exitstatus)
        raise Exceptions::SystemCommandFailed,
              "Command '#{cmd}' failed with exit code #{$?.exitstatus}: #{out}"
      end

      {output: out, exitstatus: $?.exitstatus}
    end

    def zfs(cmd, opts, component, cmd_opts = {})
      syscmd("zfs #{cmd} #{opts} #{component}", cmd_opts)
    end
  end
end
