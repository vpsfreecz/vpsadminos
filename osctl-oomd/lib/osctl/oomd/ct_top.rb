require 'json'
require 'libosctl'

module OsCtl::Oomd
  class CtTop
    include OsCtl::Lib::Utils::Log

    MAX_FRAME_BYTES = 16 * 1024 * 1024

    def self.run(rate, &)
      new(rate).run(&)
    end

    def initialize(rate)
      @rate = rate
    end

    def run(&)
      loop do
        r, w = IO.pipe
        command = ['osctl', '-j', 'ct', 'top', '--rate', @rate.to_s,
                   '--no-netif', '--no-zfs', '--no-iostat', '--no-processes']
        pid = Process.spawn(*command, out: w, close_others: true)
        w.close
        log(:info, "Started with pid #{pid}")

        yield(:child_started)
        read_child(r, &)
        r.close
        yield({})
        Process.wait(pid)
        log(:warn, "ct top exited (status #{$?.exitstatus.inspect}); retrying in 5 seconds")
        sleep(5)
      end
    end

    def log_type
      'ct-top'
    end

    protected

    def read_child(reader)
      epoch = nil
      diagnosed = false
      while (line = reader.gets("\n", MAX_FRAME_BYTES + 1))
        if line.bytesize > MAX_FRAME_BYTES || !line.end_with?("\n")
          yield({})
          line = reader.gets("\n", MAX_FRAME_BYTES + 1) until line.nil? || line.end_with?("\n")
          next
        end

        data = parse(line)
        unless typed_record?(data) && (epoch.nil? || data['epoch'] == epoch)
          yield({})
          unless diagnosed
            log(:warn, 'Ignoring invalid or unsupported ct top output')
            diagnosed = true
          end
          next
        end
        epoch ||= data['epoch']
        yield(data)
      end
    end

    def parse(line)
      JSON.parse(line)
    rescue JSON::ParserError, ArgumentError
      nil
    end

    def typed_record?(data)
      data.is_a?(Hash) && 2.eql?(data['top_schema']) && !data.has_key?('observation') &&
        data['epoch'].is_a?(String) && data['epoch'].bytesize.between?(1, 95)
    end
  end
end
