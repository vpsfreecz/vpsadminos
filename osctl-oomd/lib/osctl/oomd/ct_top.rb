require 'json'
require 'libosctl'

module OsCtl::Oomd
  class CtTop
    include OsCtl::Lib::Utils::Log

    MAX_FRAME_BYTES = 16 * 1024 * 1024

    def self.run(rate, **, &)
      new(rate, **).run(&)
    end

    def initialize(rate, watchdog: false)
      @rate = rate
      @watchdog = watchdog
    end

    def run
      loop do
        r, w = IO.pipe

        command = ['osctl', '-j', 'ct', 'top', '--rate', @rate.to_s]
        command.push('--no-netif', '--no-zfs') if @watchdog
        command.push('--no-iostat', '--no-processes')
        pid = Process.spawn(*command, out: w, close_others: true)
        w.close

        log(:info, "Started with pid #{pid}")

        until r.eof?
          begin
            if @watchdog
              line = r.gets("\n", MAX_FRAME_BYTES + 1)
              if line.nil? || line.bytesize > MAX_FRAME_BYTES || !line.end_with?("\n")
                # Reject the frame, drain bounded chunks to the next boundary.
                yield({})
                line = r.gets("\n", MAX_FRAME_BYTES + 1) until line.nil? || line.end_with?("\n")
                next
              end
              data = JSON.parse(line)
            else
              data = JSON.parse(r.readline)
            end
          rescue StandardError => e
            yield({}) if @watchdog
            message = @watchdog ? e.message.byteslice(0, 256) : e.message
            log(:warn, "Unable to parse output from ct top as JSON: #{message} (#{e.class})")
            next
          end

          yield(data)
        end

        Process.wait(pid)
        log(:info, "Exited with pid #{$?.exitstatus}")

        sleep(5)
      end
    end

    def log_type
      'ct-top'
    end
  end
end
