require 'libosctl'
require 'tty-spinner'

module OsCtl::Cli
  class Ps::Main < Command
    def run
      if opts[:list]
        puts Ps::Columns::COLS.join("\n")
        return
      end

      require_args!(optional: %w(id), strict: false)

      filters = opts[:parameter].map { |v| Ps::Filter.new(v) }

      ctids = {}

      args.each do |arg|
        if arg == '-'
          ctids[:host] = true
        elsif arg.index(':')
          pool, id = arg.split(':')
          ctids["#{pool}:#{id}"] = true
        else
          pool = gopts[:pool]
          id = arg

          if pool
            ctids["#{pool}:#{id}"] = true
          else
            ctids[id] = true
          end
        end
      end

      pl, pools = get_process_list(ctids, filters)

      cols =
        if opts[:output]
          opts[:output].split(',').map(&:to_sym)
        elsif ctids.size == 1
          Ps::Columns::DEFAULT_ONE_CT
        elsif pools.size == 1
          Ps::Columns::DEFAULT_ONE_POOL
        else
          Ps::Columns::DEFAULT_MULTIPLE_POOLS
        end

      out_cols, out_data = Ps::Columns.generate(pl, cols, gopts[:parsable])

      OsCtl::Lib::Cli::OutputFormatter.print(
        out_data,
        cols: out_cols,
        layout: :columns,
        header: opts['hide-header'] ? false : true,
        sort: opts[:sort] && opts[:sort].split(',').map(&:to_sym),
      )

      if pl.size > 1
        warn "#{pl.size} processes"
      elsif pl.size == 1
        warn "#{pl.size} process"
      else
        warn "No processes found"
      end
    end

    protected
    def get_process_list(ctids, filters)
      spinner = TTY::Spinner.new("[:spinner] :title", clear: true)
      spinner.update(title: 'Listing processes...')
      spinner.auto_spin

      list_queue = OsCtl::Lib::Queue.new
      list_thread = Thread.new { list_processes(list_queue, ctids, filters) }
      update_queue = OsCtl::Lib::Queue.new
      update_thread = Thread.new { update_loop(update_queue) }
      last_pid = nil
      @update_count = false
      total = 0
      error = false
      ret = nil

      loop do
        v = list_queue.pop(timeout: 5)

        if v.is_a?(Array)
          ret = v
          break
        end

        pid = v

        if pid.nil? && !error
          msg =
            if last_pid.nil?
              'Taking long to list /proc entries'
            else
              sprintf('Taking long to process pid %d', last_pid)
            end

          set_title(spinner, msg)
          error = true
          next
        end

        total += 1
        last_pid = pid

        if pid && error
          set_title(spinner, sprintf('Listing processes... %8d', total))
          error = false
        elsif pid
          set_title(spinner, sprintf('Listing processes... %8d', total))
          @update_count = false
        end
      end

      update_queue << :stop
      list_thread.join
      update_thread.join
      spinner.stop
      ret
    end

    def set_title(spinner, str)
      spinner.tokens[:title] = sprintf('%-40s', str)
    end

    def list_processes(queue, ctids, filters)
      pools = {}
      pl = OsCtl::Lib::ProcessList.new(parse_stat: false, parse_status: false) do |p|
        # Signal which pid we're on
        queue << p.pid

        # Filter processes
        pool, id = p.ct_id

        if !ctids.empty? \
           && !(pool.nil? && ctids[:host]) \
           && !(pool && (ctids.has_key?(id) || ctids.has_key?("#{pool}:#{id}")))
          next(false)
        end

        # Parse process files
        p.parse
        p.cmdline

        next(false) if filters.detect { |f| !f.match?(p) }

        pools[pool] = true if pool
        true
      end

      queue << [pl, pools]
    end

    def update_loop(queue)
      loop do
        return if queue.pop(timeout: 0.2) == :stop
        @update_count = true
      end
    end
  end
end
