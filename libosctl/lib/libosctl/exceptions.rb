module OsCtl::Lib
  module Exceptions
    class SystemCommandFailed < StandardError
      attr_reader :cmd, :rc, :output

      def initialize(cmd, rc, output)
        @cmd = cmd
        @rc = rc
        @output = output

        super("command '#{cmd}' exited with code '#{rc}', output: '#{output}'")
      end
    end
  end
end
