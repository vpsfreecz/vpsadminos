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

      view = klass.new(model, opts[:rate])
      view.start
    end
  end
end
