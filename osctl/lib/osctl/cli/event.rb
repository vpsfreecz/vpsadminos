require 'json'
require 'pp'
require 'osctl/cli/command'

module OsCtl::Cli
  class Event < Command
    def monitor
      c = osctld_open
      ret = c.cmd_data!(:event_subscribe)
      return if ret != 'subscribed'

      monitor_loop(c)
    end

    def monitor_ct
      c = osctld_open

      cmd_opts = {
        type: %w[config_state runtime_state state],
        opts: {}
      }
      cmd_opts[:opts][:id] = args if args.any?

      ret = c.cmd_data!(:event_subscribe, **cmd_opts)
      return if ret != 'subscribed'

      monitor_loop(c)
    end

    def wait_ct
      require_args!('id', 'runtime-state', strict: false)
      c = osctld_open

      pool = gopts[:pool]

      if args[0].index(':')
        pool, id = args[0].split(':')

      else
        id = args[0]
      end

      cmd_opts = { type: %w[runtime_state state], opts: { id: } }
      cmd_opts[:opts][:pool] = pool if pool
      states = args[1..]

      # First, subscribe for events
      ret = c.cmd_data!(:event_subscribe, **cmd_opts)
      return if ret != 'subscribed'

      # Then check the current runtime state using another connection, exit if
      # we're in an awaited state.
      ct = osctld_call(:ct_show, id:, pool:)
      return if states.include?(runtime_state_of(ct))

      # Wait for a chosen runtime state. The legacy event is accepted during
      # the first in-place upgrade.
      monitor_loop(c) do |event|
        runtime_state = if event[:type] == 'runtime_state'
                          event[:opts][:runtime_state]
                        else
                          event[:opts][:state]
                        end
        :stop if states.include?(runtime_state)
      end
    end

    def broadcast
      require_args!

      c = osctld_open

      $stdin.each_line do |line|
        events = JSON.parse(line).fetch('events').map do |event|
          {
            type: event.fetch('type'),
            opts: event.fetch('opts')
          }
        end

        c.cmd_data!(:event_broadcast, events:)
      end

      c.close
    end

    protected

    def monitor_loop(c)
      loop do
        resp = c.response!
        return if resp.data.nil?

        if block_given?
          return if yield(resp.data) == :stop

          next
        end

        if gopts[:json]
          puts resp.data.to_json

        elsif %w[management config_state runtime_state state].include?(resp.data[:type])
          send(:"print_#{resp.data[:type]}", resp.data[:opts])

        else
          p resp.data
        end

        $stdout.flush
      end
    end

    def print_management(opts)
      puts "management id=#{opts[:id]} state=#{opts[:state]} " \
           "command=#{opts[:cmd]} opts=#{PP.pp(opts[:opts], '')}"
    end

    def print_state(opts)
      puts "runtime_state #{opts[:pool]} #{opts[:id]} #{opts[:state]}"
    end

    def print_config_state(opts)
      puts "config_state #{opts[:pool]} #{opts[:id]} #{opts[:config_state]}"
    end

    def print_runtime_state(opts)
      puts "runtime_state #{opts[:pool]} #{opts[:id]} #{opts[:runtime_state]}"
    end

    def runtime_state_of(ct)
      return ct[:runtime_state] if ct[:runtime_state]

      %w[staged error].include?(ct[:state]) ? 'unknown' : ct[:state]
    end
  end
end
