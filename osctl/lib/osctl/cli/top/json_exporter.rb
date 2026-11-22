require 'libosctl'
require 'json'
require 'osctl/cli/top/view'

module OsCtl::Cli
  class Top::JsonExporter < Top::View
    def start
      queue = OsCtl::Lib::Queue.new

      Signal.trap('USR1') do
        Thread.new { queue << nil }
      end

      loop do
        queue.pop(timeout: rate)
        queue.clear

        model.measure
        puts model.json_data.to_json
        $stdout.flush
      end
    end
  end
end
