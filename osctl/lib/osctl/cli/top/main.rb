require 'osctl/cli/command'

module OsCtl::Cli
  class Top::Main < Command
    def start
      validate_rate
      json = gopts[:json]
      collectors = {
        enable_netif: opts.fetch(:netif, true),
        enable_zfs: opts.fetch(:zfs, true),
        enable_iostat: opts.fetch(:iostat, true)
      }
      model = Top::PartialModel.new(json: json == true, **collectors)
      model.setup

      kwargs = {}

      if json
        klass = Top::JsonExporter

      else
        klass = Top::Tui
        kwargs = { enable_procs: opts[:processes] }
      end

      view = klass.new(model, opts[:rate], **kwargs)
      view.start
    rescue Top::PartialModel::MonitorLost => e
      raise GLI::CustomExit.new(e.message, 1)
    ensure
      model&.stop if json
    end

    protected

    def validate_rate
      rate = opts[:rate]
      return if rate && rate > 0 && rate.finite?

      raise GLI::BadCommandLine, 'rate must be a positive finite number'
    end
  end
end
