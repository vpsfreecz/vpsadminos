module OsCtl::Lib
  class ProcessList < Array
    def initialize(&block)
      list_processes(&block)
    end

    protected
    def list_processes
      Dir.foreach('/proc') do |entry|
        next if /^\d+$/ !~ entry || !Dir.exist?(File.join('/proc', entry))

        begin
          p = OsProcess.new(entry.to_i)
          next if block_given? && !yield(p)

          self << p
        rescue Exceptions::OsProcessNotFound
          next
        end
      end
    end
  end
end
