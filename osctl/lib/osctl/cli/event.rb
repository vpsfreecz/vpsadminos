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

      cmd_opts = {type: 'state', opts: {}}
      cmd_opts[:opts][:id] = args if args.any?

      ret = c.cmd_data!(:event_subscribe, cmd_opts)
      return if ret != 'subscribed'

      monitor_loop(c)
    end

    def wait_ct
      require_args!('id', 'state')
      c = osctld_open

      pool = gopts[:pool]

      if args[0].index(':')
        pool, id = args[0].split(':')

      else
        id = args[0]
      end

      cmd_opts = {type: 'state', opts: {id: id}}
      cmd_opts[:opts][:pool] = pool if pool
      states = args[1..-1]

      # First, subscribe for events
      ret = c.cmd_data!(:event_subscribe, cmd_opts)
      return if ret != 'subscribed'

      # Then check the current state using another connection, exit if we're
      # in awaited state
      ct = osctld_call(:ct_show, id: args[0], pool: gopts[:pool])
      return if states.include?(ct[:state])

      # Wait for chosen state
      monitor_loop(c) do |event|
        :stop if states.include?(event[:opts][:state])
      end
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

        elsif %w(management state).include?(resp.data[:type])
          send(:"print_#{resp.data[:type]}", resp.data[:opts])

        else
          p resp.data
        end

        STDOUT.flush
      end
    end

    def print_management(opts)
      puts "management id=#{opts[:id]} state=#{opts[:state]} "+
           "command=#{opts[:cmd]} opts=#{PP.pp(opts[:opts], '')}"
    end

    def print_state(opts)
      puts "state #{opts[:pool]} #{opts[:id]} #{opts[:state]}"
    end
  end
end
