require 'osctl/cli/command'

module OsCtl::Cli
  class Top::Main < Command
    def start
      validate_rate

      model = Top::Model.new(enable_iostat: opts[:iostat])
      model.setup

      kwargs = {}

      if gopts[:json]
        klass = Top::JsonExporter

      else
        klass = Top::Tui
        kwargs = { enable_procs: opts[:processes] }
      end

      view = klass.new(model, opts[:rate], **kwargs)
      view.start
    end

    protected

    def validate_rate
      rate = opts[:rate]
      return if rate && rate > 0 && rate.finite?

      raise GLI::BadCommandLine, 'rate must be a positive finite number'
    end
  end
end
