require 'libosctl'
require 'tty-spinner'

module OsCtl::Cli
  class Ps::Main < Command
    SlowOsProcess = Struct.new(:os_process, :duration)

    READ_TIMEOUT = 1

    def run
      param_selector = OsCtl::Lib::Cli::ParameterSelector.new(
        all_params: Ps::Columns::COLS,
      )

      if opts[:list]
        puts param_selector
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

      pl, pools, slow_os_procs = get_process_list(ctids, filters)

      default_cols =
        if ctids.size == 1
          Ps::Columns::DEFAULT_ONE_CT
        elsif pools.size == 1
          Ps::Columns::DEFAULT_ONE_POOL
        else
          Ps::Columns::DEFAULT_MULTIPLE_POOLS
        end

      out_cols, out_data = Ps::Columns.generate(
        pl,
        param_selector.parse_option(opts[:output], default_params: default_cols),
        gopts[:parsable],
      )

      OsCtl::Lib::Cli::OutputFormatter.print(
        out_data,
        cols: out_cols,
        layout: :columns,
        header: opts['hide-header'] ? false : true,
        sort: opts[:sort] && param_selector.parse_option(opts[:sort]),
      )

      if pl.size > 1
        warn "#{pl.size} processes"
      elsif pl.size == 1
        warn "#{pl.size} process"
      else
        warn "No processes found"
      end

      if slow_os_procs.any?
        warn "\nSlow processes:"
        slow_os_procs.sort do |a, b|
          b.duration <=> a.duration
        end.each do |slow_proc|
          pool, id = slow_proc.os_process.ct_id
          ctid = pool.nil? ? '[host]' : "#{pool}:#{id}"
          warn(sprintf(
            '%16s: %10d %-18s %.2fs',
            ctid,
            slow_proc.os_process.pid,
            slow_proc.os_process.name,
            slow_proc.duration,
          ))
        end
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
      last_os_proc = nil
      last_time = nil
      slow_os_procs = []
      @update_count = false
      total = 0
      error = false
      ret = nil

      loop do
        v = list_queue.pop(timeout: READ_TIMEOUT)

        if v.is_a?(Array)
          ret = v
          ret << slow_os_procs
          break
        end

        os_proc = v

        if os_proc.nil? && !error
          msg =
            if last_os_proc.nil?
              'Taking long to list /proc entries'
            else
              sprintf('Taking long to process pid %d', last_os_proc.pid)
            end

          set_title(spinner, msg)

          if last_os_proc
            slow_os_procs << SlowOsProcess.new(last_os_proc, 0)
            last_time = Time.now - READ_TIMEOUT
          end

          error = true
          next
        end

        if os_proc && last_time
          slow_os_procs.last.duration = Time.now - last_time
          last_time = nil
        end

        total += 1
        last_os_proc = os_proc

        if os_proc && error
          set_title(spinner, sprintf('Listing processes... %8d', total))
          error = false
        elsif os_proc
          set_title(spinner, sprintf('Listing processes... %8d', total))
          @update_count = false
        end
      end

      if last_time
        slow_os_procs.last.duration = Time.now - last_time
        last_time = nil
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
        queue << p

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
