require 'libosctl'

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

      pl = OsCtl::Lib::ProcessList.new do |p|
        pool, id = p.ct_id

        # All processes
        if ctids.empty?
          true
        # Host processes
        elsif pool.nil? && ctids[:host]
          true
        # Filter processes by ctid
        elsif pool && (ctids.has_key?(id) || ctids.has_key?("#{pool}:#{id}"))
          true
        # Reject the rest
        else
          false
        end
      end

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
  end
end
