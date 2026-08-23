require 'osctl/cli/command'

module OsCtl::Cli
  class Daemon < Command
    def status
      data = osctld_call(:daemon_status)
      print_status(data)
    rescue OsCtl::Client::Error => e
      raise unless e.message.include?("Unsupported command 'daemon_status'")

      legacy = osctld_call(:self_status)
      print_status({
                     schema: 0,
                     legacy: true,
                     started_at: legacy[:started_at],
                     initialized: legacy[:initialized],
                     phase: legacy[:initialized] ? 'ready' : 'starting',
                     ready: legacy[:initialized],
                     lifecycle_admission: legacy[:initialized]
                   })
    end

    def prepare_stop
      osctld_fmt(:daemon_prepare_stop)
    end

    def resume
      osctld_fmt(:daemon_resume)
    end

    def wait_ready
      osctld_fmt(
        :daemon_wait_ready,
        cmd_opts: { timeout: opts[:timeout] }
      )
    end

    protected

    def print_status(data)
      if gopts[:json]
        puts data.to_json
        return
      end

      puts "phase: #{data[:phase]}"
      puts "ready: #{data[:ready] ? 'yes' : 'no'}"
      puts "lifecycle admission: #{data[:lifecycle_admission] ? 'open' : 'closed'}"
      puts "legacy daemon: #{data[:legacy] ? 'yes' : 'no'}"
      puts "failures: #{Array(data[:failures]).length}" if data.has_key?(:failures)
      puts "orphans: #{Array(data[:orphans]).length}" if data.has_key?(:orphans)
      puts "drain blockers: #{Array(data[:drain_blockers]).length}" \
        if data.has_key?(:drain_blockers)
    end
  end
end
