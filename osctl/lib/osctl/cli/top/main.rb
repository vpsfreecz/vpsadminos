module OsCtl::Cli
  class Top::Main < Command
    def start
      model = Top::Model.new
      model.setup

      if gopts[:parsable]
        klass = Top::JsonExporter

      else
        klass = Top::Tui
      end

      renderer = klass.new(model, opts[:rate])
      renderer.start
    end
  end
end
