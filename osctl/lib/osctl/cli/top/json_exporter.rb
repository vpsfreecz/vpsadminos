require 'json'

module OsCtl::Cli
  class Top::JsonExporter < Top::Renderer
    def start
      loop do
        sleep(rate)

        model.measure
        puts model.data.to_json
      end
    end
  end
end
