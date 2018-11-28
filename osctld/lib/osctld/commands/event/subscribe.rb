require 'osctld/commands/base'

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
        event = queue.pop(timeout: 0.2)

        if event.nil?
          if @do_stop
            Eventd.unsubscribe(queue)
            return error('osctld is shutting down')
          end
        elsif !filter?(event)
          next
        elsif !client_handler.reply_ok(export_event(event))
          break
        end
      end

      log(:info, :eventd, 'Unsubscribing client')
      Eventd.unsubscribe(queue)
      ok
    end

    def request_stop
      @do_stop = true
    end

    protected
    def filter?(event)
      if opts[:type]
        if opts[:type].is_a?(Array)
          return false if opts[:type].include?(event.type)
        else
          return false if opts[:type] != event.type.to_s
        end
      end

      if opts[:opts]
        opts[:opts].each do |k, v|
          if v.is_a?(Array)
            return false if !v.include?(event.opts[k])

          else
            return false if v != event.opts[k]
          end
        end
      end

      true
    end

    def export_event(e)
      {
        type: e.type,
        opts: e.opts,
      }
    end
  end
end
