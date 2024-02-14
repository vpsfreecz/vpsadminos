require 'libosctl'

module OsCtld
  # Update container hints at regular intervals
  class HintUpdater
    include OsCtl::Lib::Utils::Log
    include OsCtl::Lib::Utils::Exception

    # @param pool [Pool]
    def initialize(pool)
      @pool = pool
      @ct_queue = OsCtl::Lib::Queue.new
    end

    def start
      raise 'already started' if @ct_thread

      @stop = false
      @ct_thread = Thread.new { run_ct_updates }
    end

    def stop
      return unless @ct_thread

      @stop = true
      @ct_queue.clear
      @ct_queue << :stop
      @ct_thread.join
      @ct_thread = nil
    end

    def log_type
      @pool.name
    end

    protected

    def run_ct_updates
      loop do
        v = @ct_queue.pop(timeout: 8 * 60 * 60)
        return if v == :stop

        t1 = Time.now
        log(:info, 'Updating container hints')

        DB::Containers.get.each do |ct|
          return if @stop

          next if ct.pool != @pool || !ct.running?

          begin
            ct.update_hints
          rescue StandardError => e
            log(:warn, ct, "Unable to update hints: #{e.message} (#{e.class})")
            log(:warn, ct, denixstorify(e.backtrace))
          end

          sleep(0.2)
        end

        log(:info, "Finished updating container hints in #{(Time.now - t1).round(2)}s")
      end
    end
  end
end
