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

    class OsProcessNotFound < StandardError
      def initialize(pid)
        super("process #{pid} not found")
      end
    end

    class IdMappingError < StandardError
      # @param idmap [IdMap]
      # @param id [Integer]
      def initialize(idmap, id)
        super("unable to map id #{id} using #{idmap.to_s}")
      end
    end
  end
end
