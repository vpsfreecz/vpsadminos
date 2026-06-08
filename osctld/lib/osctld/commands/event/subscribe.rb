require 'osctld/commands/base'
require 'osctld/eventd/event'

module OsCtld
  class Commands::Event::Subscribe < Commands::Base
    handle :event_subscribe

    include OsCtl::Lib::Utils::Log

    def execute
      log(:info, :eventd, 'Subscribing client')
      queue = Eventd.subscribe
      client_handler.reply_ok('subscribed')

      opts.delete(:cli)

      loop do
        if @do_stop
          send_shutdown_event
          Eventd.unsubscribe(queue)
          return error('osctld is shutting down')
        end

        event = queue.pop(timeout: 0.2)

        next if event.nil? || !filter?(event)

        break unless client_handler.reply_ok(export_event(event))
      end

      log(:info, :eventd, 'Unsubscribing client')
      Eventd.unsubscribe(queue)
      ok
    end

    def request_stop
      @do_stop = true
    end

    protected

    def send_shutdown_event
      event = Eventd::Event.new(:osctld_shutdown, {})

      return unless filter?(event)

      client_handler.reply_ok(export_event(event))
    end

    def filter?(event)
      if opts[:type]
        event_type = event.type.to_s

        if opts[:type].is_a?(Array)
          return false unless opts[:type].map(&:to_s).include?(event_type)
        elsif opts[:type].to_s != event_type
          return false
        end
      end

      if opts[:opts]
        opts[:opts].each do |k, v|
          if v.is_a?(Array)
            return false unless v.include?(event.opts[k])

          elsif v != event.opts[k]
            return false
          end
        end
      end

      true
    end

    def export_event(e)
      {
        type: e.type,
        opts: e.opts
      }
    end
  end
end
