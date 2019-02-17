module OsCtl::Lib
  # Locate containers by process IDs from the host
  class PidFinder
    Result = Struct.new(:pool, :ctid, :os_process)

    # @param pid [Integer] process ID from the host
    # @return [Result, nil]
    def find(pid)
      os_proc = OsProcess.new(pid)
      ctid = os_proc.ct_id

      if ctid.nil?
        Result.new(nil, :host, os_proc)
      else
        pool, id = ctid
        Result.new(pool, id, os_proc)
      end

    rescue Exceptions::OsProcessNotFound
      nil
    end
  end
end
