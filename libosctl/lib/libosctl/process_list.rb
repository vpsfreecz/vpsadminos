module OsCtl::Lib
  class ProcessList < Array
    # Iterate over all processes
    # @param opts [Hash] options passed to {OsProcess}
    # @yieldparam [OsProcess] process
    def self.each(**opts, &block)
      new(**opts) do |p|
        block.call(p)
        next(false)
      end

      nil
    end

    # Create an array of system processes
    #
    # The block can be used to filter out processes for which it returns false.
    #
    # @param opts [Hash] options passed to {OsProcess}
    # @yieldparam [OsProcess] process
    def initialize(**, &)
      super()
      list_processes(**, &)
    end

    protected

    def list_processes(**opts)
      Dir.foreach('/proc') do |entry|
        next if /^\d+$/ !~ entry || !Dir.exist?(File.join('/proc', entry))

        begin
          p = OsProcess.new(entry.to_i, **opts)
          next if block_given? && !yield(p)

          self << p
        rescue Exceptions::OsProcessNotFound
          next
        end
      end
    end
  end
end
