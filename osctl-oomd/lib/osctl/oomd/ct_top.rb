require 'json'
require 'libosctl'

module OsCtl::Oomd
  class CtTop
    include OsCtl::Lib::Utils::Log

    def self.run(rate, &)
      new(rate).run(&)
    end

    def initialize(rate)
      @rate = rate
    end

    def run
      loop do
        r, w = IO.pipe

        pid = Process.spawn(
          'osctl', '-j', 'ct', 'top', '--rate', @rate.to_s, '--no-iostat', '--no-processes',
          out: w, close_others: true
        )
        w.close

        log(:info, "Started with pid #{pid}")

        until r.eof?
          begin
            data = JSON.parse(r.readline)
          rescue StandardError => e
            log(:warn, "Unable to parse output from ct top as JSON: #{e.message} (#{e.class})")
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
