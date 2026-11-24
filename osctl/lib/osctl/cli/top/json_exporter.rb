require 'libosctl'
require 'json'
require 'osctl/cli/top/view'

module OsCtl::Cli
  class Top::JsonExporter < Top::View
    def start
      queue = model.sample_wakeup

      previous_handler = Signal.trap('USR1') do
        Thread.new { queue << :refresh }
      end

      loop do
        model.check_monitor!
        queue.pop(timeout: rate)
        queue.clear

        model.check_monitor!
        model.measure
        record = model.json_data.to_json
        model.check_monitor!
        puts record
        $stdout.flush
      end
    ensure
      Signal.trap('USR1', previous_handler) if previous_handler
    end
  end
end
