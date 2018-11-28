require 'osctld/commands/base'

module OsCtld
  class Commands::Debug::ThreadList < Commands::Base
    handle :debug_thread_list

    def execute
      ok(ThreadReaper.export.map do |thread, manager|
        {
          thread: thread.to_s,
          manager: manager.to_s,
          backtrace: thread.backtrace,
        }
      end)
    end
  end
end
