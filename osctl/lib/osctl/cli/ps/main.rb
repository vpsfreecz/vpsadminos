require 'libosctl'

module OsCtl::Cli
  class Ps::Main < Command
    def run
      if opts[:list]
        puts Ps::Columns::COLS.join("\n")
        return
      end

      require_args!('id')

      if args[0].index(':')
        pool, id = args[0].split(':')
      else
        pool = gopts[:pool]
        id = args[0]
      end

      pl = OsCtl::Lib::ProcessList.new do |p|
        ctid = p.ct_id

        if ctid.nil? || (pool && ctid[0] != pool) || (ctid[1] != id)
          false
        else
          true
        end
      end

      cols = opts[:output] ? opts[:output].split(',').map(&:to_sym) : Ps::Columns::DEFAULT
      out_cols, out_data = Ps::Columns.generate(pl, cols, gopts[:parsable])

      OutputFormatter.print(
        out_data,
        out_cols,
        layout: :columns,
        header: opts['hide-header'] ? false : true,
        sort: opts[:sort] && opts[:sort].split(',').map(&:to_sym),
      )
    end
  end
end
