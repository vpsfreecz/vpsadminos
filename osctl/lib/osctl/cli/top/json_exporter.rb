require 'json'
require 'osctl/cli/top/view'

module OsCtl::Cli
  class Top::JsonExporter < Top::View
    class Wake < StandardError ; end

    def start
      Signal.trap('USR1') do
        raise Wake
      end

      loop do
        begin
          sleep(rate)

        rescue Wake
          # continue
        end

        model.measure
        puts model.data.to_json
        STDOUT.flush
      end
    end
  end
end
