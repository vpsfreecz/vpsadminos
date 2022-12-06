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

      pl = get_process_list(ctids)

      cols =
        if opts[:output]
          opts[:output].split(',').map(&:to_sym)
        else
          ctids.size == 1 ? Ps::Columns::DEFAULT_CT : Ps::Columns::DEFAULT_ALL
        end

      out_cols, out_data = Ps::Columns.generate(pl, cols, gopts[:parsable])

      OsCtl::Lib::Cli::OutputFormatter.print(
        out_data,
        cols: out_cols,
        layout: :columns,
        header: opts['hide-header'] ? false : true,
        sort: opts[:sort] && opts[:sort].split(',').map(&:to_sym),
      )
    end

    protected
    def get_process_list(ctids)
      spinner = TTY::Spinner.new("[:spinner] :title", clear: true)
      spinner.update(title: 'Listing processes...')
      spinner.auto_spin

      queue = OsCtl::Lib::Queue.new
      thread = Thread.new { list_processes(queue, ctids) }
      last_pid = nil
      error = false
      ret = nil

      loop do
        pid = queue.pop(timeout: 5)

        if pid.is_a?(OsCtl::Lib::ProcessList)
          ret = pid
          break
        end

        if pid.nil? && !error
          msg =
            if last_pid.nil?
              'Taking long to list /proc entries'
            else
              "Taking long to process pid #{last_pid}"
            end

          spinner.update(title: msg)
          error = true
          next
        end

        if pid && error
          spinner.update(title: 'Listing processes...')
          error = false
        end

        last_pid = pid
      end

      thread.join
      spinner.stop
      ret
    end

    def list_processes(queue, ctids)
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
      end

      queue << pl
    end
  end
end
