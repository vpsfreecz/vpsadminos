require 'thread'

module OsCtl::Cli
  class Top::Monitor
    def initialize(model)
      @model = model
      @started = false
      @buffer = []
    end

    def subscribe
      @client = OsCtl::Client.new
      client.open

      ret = client.cmd_data!(:event_subscribe)
      return if ret != 'subscribed'

      @thread = Thread.new do
        monitor_loop do |event|
          if started?
            process_saved_events
            process_event(event[:type].to_sym, event[:opts])
          else
            save_event(event)
          end
        end
      end
    end

    def start
      @started = true
    end

    def stop
      client.close
      thread.join
    end

    protected
    attr_reader :client, :thread, :model

    def monitor_loop
      loop do
        resp = client.response!
        return if resp.data.nil?

        return if yield(resp.data) == :stop
      end
    end

    def process_event(type, opts)
      case type
      when :state
        model.sync do
          ct = model.find_ct(opts[:pool], opts[:id])
          next unless ct

          ct.state = opts[:state].to_sym
        end

      when :db
        model.sync do
          if opts[:object] == 'pool'
            case opts[:action].to_sym
            when :add
              unless model.has_pool?(opts[:pool])
                model.add_pool(opts[:pool])
              end

            when :remove
              model.remove_pool(opts[:pool])
            end

          elsif opts[:object] == 'container'
            case opts[:action].to_sym
            when :add
              unless model.has_ct?(opts[:pool], opts[:id])
                model.add_ct(opts[:pool], opts[:id])
              end

            when :remove
              ct = model.find_ct(opts[:pool], opts[:id])
              model.remove_ct(ct) if ct
            end
          end
        end

      when :ct_netif
        model.sync do
          ct = model.find_ct(opts[:pool], opts[:id])
          next unless ct

          case opts[:action].to_sym
          when :add
            model.add_ct_netif(ct, opts[:name]) unless ct.has_netif?(opts[:name])

          when :remove
            ct.netif_rm(opts[:name]) if ct.has_netif?(opts[:name])

          when :rename
            if ct.has_netif?(opts[:name])
              ct.netif_rename(opts[:name], opts[:new_name])
            end

          when :up
            if ct.has_netif?(opts[:name])
              ct.netif_up(opts[:name], opts[:veth])
            end

          when :down
            if ct.has_netif?(opts[:name])
              ct.netif_down(opts[:name])
            end
          end
        end
      end
    end

    def save_event(event)
      @buffer << event
    end

    def process_saved_events
      return if @buffer.empty?
      @buffer.each { |event| process_event(event[:type].to_sym, event[:opts]) }
      @buffer.clear
    end

    def started?
      @started
    end
  end
end
