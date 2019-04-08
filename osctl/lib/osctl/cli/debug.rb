module OsCtl::Cli
  class Debug < Command
    LOCK_FIELDS = %i(
      id
      time
      thread
      object
      type
      state
      backtrace
    )

    def locks_ls
      data = osctld_call(:debug_lock_registry)

      if opts[:verbose]
        format_output(
          data.map do |lock|
            lock[:backtrace] = lock[:backtrace].join("\n")
            lock
          end,
          %i(id time thread object type state backtrace),
          {layout: :rows}
        )

      else
        format_output(
          data,
          %i(id thread object type state),
          {layout: :columns}
        )
      end
    end

    def locks_show
      require_args!('id')
      id = args[0].to_i

      data = osctld_call(:debug_lock_registry)
      lock = data.detect { |v| v[:id] == id }
      return unless lock

      lock[:backtrace] = lock[:backtrace].join("\n")
      format_output(lock)
    end

    def threads_ls
      data = osctld_call(:debug_thread_list)
      data.map do |thread|
        thread[:backtrace] = thread[:backtrace] && thread[:backtrace].join("\n")
        thread
      end
      format_output(data, nil, {layout: :rows})
    end

    def ugids_ls
      data = osctld_call(:debug_ugid_registry)

      if args[0].nil? || args[0] == 'all'
        format_output(
          (data[:allocated] + data[:free]).sort!.map! do |ugid|
            {
              ugid: ugid,
              free: !data[:allocated].include?(ugid),
            }
          end,
          nil,
          {layout: :columns}
        )

      elsif args[0] == 'taken'
        data[:allocated].each { |ugid| puts ugid }

      elsif args[0] == 'free'
        data[:free].each { |ugid| puts ugid }

      else
        raise GLI::BadCommandLine
      end
    end
  end
end
