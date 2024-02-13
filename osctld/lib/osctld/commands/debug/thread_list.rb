require 'libosctl'
require 'osctld/commands/base'

module OsCtld
  class Commands::Debug::ThreadList < Commands::Base
    handle :debug_thread_list

    include OsCtl::Lib::Utils::Exception

    def execute
      ok(ThreadReaper.export.map do |thread, manager|
        {
          thread: thread.to_s,
          manager: manager.to_s,
          backtrace: thread.backtrace && denixstorify(thread.backtrace)
        }
      end)
    end
  end
end
