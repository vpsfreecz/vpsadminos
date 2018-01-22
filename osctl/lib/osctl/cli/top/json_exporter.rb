require 'json'

module OsCtl::Cli
  class Top::JsonExporter < Top::View
    def start
      loop do
        sleep(rate)

        model.measure
        puts model.data.to_json
      end
    end
  end
end
