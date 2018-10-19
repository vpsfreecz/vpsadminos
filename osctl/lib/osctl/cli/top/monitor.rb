require 'thread'

module OsCtl::Cli
  class Top::Monitor
    def initialize(model)
      @model = model
    end

    def start
      @client = OsCtl::Client.new
      client.open

      ret = client.cmd_data!(:event_subscribe)
      return if ret != 'subscribed'

      @thread = Thread.new do
        monitor_loop do |event|
          process_event(event[:type].to_sym, event[:opts])
        end
      end
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
          ct = find_ct(opts[:pool], opts[:id])
          fail "container #{opts[:pool]}:#{opts[:id]} not found" unless ct

          ct.state = opts[:state].to_sym
        end

      when :db
        return if opts[:object] != 'container'

        case opts[:action].to_sym
        when :add
          model.add_ct(opts[:pool], opts[:id])

        when :remove
          model.sync do
            ct = find_ct(opts[:pool], opts[:id])
            next unless ct

            model.remove_ct(ct)
          end
        end

      when :ct_netif
        model.sync do
          ct = find_ct(opts[:pool], opts[:id])
          next unless ct

          case opts[:action].to_sym
          when :add
            model.add_ct_netif(ct, opts[:name])

          when :remove
            ct.netif_rm(opts[:name])

          when :rename
            ct.netif_rename(opts[:name], opts[:new_name])

          when :up
            ct.netif_up(opts[:name], opts[:veth])

          when :down
            ct.netif_down(opts[:name])
          end
        end
      end
    end

    def find_ct(pool, id)
      model.sync do
        model.containers.detect do |ct|
          ct.pool == pool && ct.id == id
        end
      end
    end
  end
end
