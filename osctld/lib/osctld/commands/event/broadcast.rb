require 'osctld/commands/base'

module OsCtld
  class Commands::Event::Broadcast < Commands::Base
    handle :event_broadcast

    include OsCtl::Lib::Utils::Log

    def execute
      begin
        events = opts.fetch(:events)
      rescue KeyError => e
        error!("missing events: #{e.message}")
      end

      events.each do |event|
        begin
          event_type = event.fetch(:type)
          event_opts = event.fetch(:opts)
        rescue KeyError => e
          error!("invalid options: #{e.message}")
        end

        if !event_type.is_a?(String)
          error!('type must be a string')
        elsif !event_opts.is_a?(Hash)
          error!('opts must be a hash')
        end

        Eventd.broadcast(event_type, **event_opts)
      end

      ok
    end
  end
end
