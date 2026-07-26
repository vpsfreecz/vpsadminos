require 'libosctl'
require 'json'
require 'socket'

module OsCtld
  class Cli::Exec
    CONTROL_SOCKET = '/run/osctl/osctld.sock'.freeze

    def self.run
      if ARGV.size < 3 || ARGV[1] != '--'
        warn 'Usage: <settings file> -- <command> [arguments...]'
        exit(false)
      end

      OsCtl::Lib::Logger.setup(:none)
      CGroup.init

      cfg = JSON.parse(File.read(ARGV[0]), symbolize_names: true)
      attachment = cfg[:attachment]

      if attachment
        control_attachment(:activate, attachment)
        status = nil
        pid = nil
        waited = false
        gate_r, gate_w = IO.pipe
        begin
          prepare_cgroup(cfg)
          pid = Process.fork do
            gate_w.close
            exit(false) unless gate_r.gets&.strip == 'ready'

            gate_r.close
            exec_command(cfg)
          end
          gate_r.close
          control_attachment(
            :handoff,
            attachment.merge(pid:)
          )
          gate_w.puts('ready')
          gate_w.close
          _, status = Process.wait2(pid)
          waited = true
        ensure
          gate_r.close unless gate_r.closed?
          gate_w.close unless gate_w.closed?
          if pid && !waited
            begin
              _, status = Process.wait2(pid)
            rescue Errno::ECHILD
              nil
            end
          end
          control_attachment(:finish, attachment)
        end

        exit(status&.exitstatus || (status&.termsig ? 128 + status.termsig : 1))
      end

      prepare_cgroup(cfg)
      exec_command(cfg)
    end

    def self.prepare_cgroup(cfg)
      CGroup.mkpath_all(
        cfg.fetch(:cgroup_path).split('/'),
        chown: cfg.fetch(:ugid)
      )
    end

    def self.exec_command(cfg)
      SwitchUser.apply_prlimits(Process.pid, cfg[:prlimits])
      SwitchUser.switch_to(
        cfg[:user],
        cfg[:ugid],
        cfg[:homedir],
        cfg[:cgroup_path],
        syslogns_pid: cfg[:syslogns_pid]
      )
      Process.exec(*ARGV[2..])
    end

    def self.control_attachment(action, attachment)
      socket = UNIXSocket.new(CONTROL_SOCKET)
      read_response(socket)
      socket.puts(
        {
          cmd: :"ct_attachment_#{action}",
          opts: attachment
        }.to_json
      )
      response = read_response(socket)
      unless response[:status] == true
        raise "unable to #{action} container attachment: " \
              "#{response[:message]}"
      end

      true
    ensure
      socket&.close
    end

    def self.read_response(socket)
      loop do
        response = JSON.parse(socket.readline, symbolize_names: true)
        next if response[:progress]

        return response
      end
    rescue EOFError
      raise 'osctld closed the attachment control connection'
    end

    private_class_method :control_attachment,
                         :exec_command,
                         :prepare_cgroup,
                         :read_response
  end
end
