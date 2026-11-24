module OsCtl::Cli
  class Top::Monitor
    MAX_BUFFERED_EVENTS = 4096
    STOP_GRACE = 0.25

    class LookupCancelled < StandardError; end

    def initialize(model)
      @model = model
      @started = false
      @acknowledged = false
      @failed = false
      @event_mutex = Mutex.new
      @lookup_mutex = Mutex.new
      @buffer = []
    end

    def subscribe
      @client = OsCtl::Client.new
      client.open
      @connected = true

      ret = client.cmd_data!(:event_subscribe)
      return lost_subscription unless ret == 'subscribed'

      @acknowledged = true
      @thread = Thread.new { monitor_loop }
    rescue StandardError
      lost_subscription
    end

    def start
      @event_mutex.synchronize do
        return unless @acknowledged && !@failed

        process_saved_events
        @started = true
        model.monitor_ready
      end
    rescue StandardError
      lost_subscription
    end

    def stop
      @lookup_mutex.synchronize { @stopping = true }
      close_client
      return if !thread || thread.join(STOP_GRACE)

      # Closing the subscription cannot wake a lookup on another connection.
      # Interrupt only the worker's lookup, never collector start/stop or event bookkeeping.
      @lookup_mutex.synchronize { thread.raise(LookupCancelled) if @lookup_active }
      thread.join
    end

    def with_lookup(&lookup)
      return lookup.call unless Thread.current == thread

      Thread.handle_interrupt(LookupCancelled => :never) do
        @lookup_mutex.synchronize do
          raise LookupCancelled if @stopping

          @lookup_active = true
        end
        begin
          Thread.handle_interrupt(LookupCancelled => :immediate, &lookup)
        ensure
          @lookup_mutex.synchronize { @lookup_active = false }
        end
      end
    end

    protected

    attr_reader :client, :thread, :model

    def monitor_loop
      loop do
        event = client.response!.data
        break unless event

        @event_mutex.synchronize do
          break if @failed || @stopping

          @started ? deliver(event) : save_event(event)
        end
        break if @failed || @stopping
      end
    rescue StandardError
      nil
    ensure
      lost_subscription
    end

    def lost_subscription
      @event_mutex.synchronize do
        unless @failed || @stopping
          @failed = true
          @buffer.clear
          model.monitor_unavailable(startup: !@acknowledged)
        end
      end
      close_client
    end

    def close_client
      connection = @lookup_mutex.synchronize do
        current = @client
        @client = nil
        current
      end
      connection.close if connection && (@connected || connection.socket)
    rescue IOError, SystemCallError
      nil
    end

    def deliver(event)
      raise ArgumentError, 'invalid event' unless event.is_a?(Hash) && event[:type].is_a?(String) && event[:opts].is_a?(Hash)

      type = event[:type].to_sym
      opts = event[:opts]
      return if type == :ct_netif && !model.netif_enabled?

      keys = case type
             when :state then %i[pool id state]
             when :ct_scheduled, :ct_init_pid then %i[pool id]
             when :ct_netif then %i[pool id action name]
             when :db
               case opts[:object]
               when 'pool' then %i[pool action]
               when 'container' then %i[pool id action]
               else []
               end
             else []
             end
      unless keys.all? { |key| opts[key].is_a?(String) && !opts[key].empty? }
        raise ArgumentError, 'event cannot be attributed'
      end

      process_event(type, opts)
    end

    def process_event(type, opts)
      return if type == :ct_netif && !model.netif_enabled?

      case type
      when :state
        model.sync do
          ct = model.find_ct(opts[:pool], opts[:id])
          unless ct
            model.missing_lifecycle(opts[:pool], opts[:id])
            next
          end

          st = opts[:state].to_sym

          ct.state = st
          ct.init_pid = opts[:init_pid] if st == :running
          model.changed!(:lifecycle, ct.ident)
        end

      when :db
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
            model.sync { model.missing_lifecycle(opts[:pool], opts[:id]) }
            unless model.has_ct?(opts[:pool], opts[:id])
              model.add_ct(opts[:pool], opts[:id])
            end

          when :remove
            model.sync do
              ct = model.find_ct(opts[:pool], opts[:id])
              ct ? model.remove_ct(ct) : model.missing_lifecycle(opts[:pool], opts[:id])
            end
          end
        end

      when :ct_scheduled
        model.sync do
          ct = model.find_ct(opts[:pool], opts[:id])
          next unless ct

          ct.cpu_package_inuse = opts[:cpu_package_inuse]
          model.changed!(:metadata, ct.ident)
        end

      when :ct_init_pid
        model.sync do
          ct = model.find_ct(opts[:pool], opts[:id])
          unless ct
            model.missing_lifecycle(opts[:pool], opts[:id])
            next
          end

          ct.init_pid = opts[:init_pid]
          model.changed!(:lifecycle, ct.ident)
        end

      when :ct_netif
        if opts[:action] == 'add'
          ct = model.sync do
            current = model.find_ct(opts[:pool], opts[:id])
            model.changed!(:netif, "#{opts[:pool]}:#{opts[:id]}")
            current
          end
          model.add_ct_netif(ct, opts[:name]) if ct && !ct.has_netif?(opts[:name])
          return
        end
        model.sync do
          ct = model.find_ct(opts[:pool], opts[:id])
          next unless ct

          case opts[:action].to_sym
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
          model.changed!(:netif, ct.ident)
        end
      end
    end

    def save_event(event)
      return if event[:type].to_s == 'ct_netif' && !model.netif_enabled?

      raise 'Top event buffer overflow' unless @buffer.size < MAX_BUFFERED_EVENTS

      @buffer << event
    end

    def process_saved_events
      @buffer.each { |event| deliver(event) }
      @buffer.clear
    end
  end
end
