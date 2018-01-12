module OsCtld
  class Commands::Container::Start < Commands::Base
    handle :ct_start

    include Utils::Log
    include Utils::System
    include Utils::SwitchUser

    def execute
      ct = DB::Containers.find(opts[:id], opts[:pool]) || (raise 'container not found')
      ct.exclusively do
        next ok if ct.running? && !opts[:force]

        # Reset log file
        File.open(ct.log_path, 'w').close
        File.chmod(0660, ct.log_path)
        File.chown(0, ct.user.ugid, ct.log_path)

        in_pipe, out_pipe = Console.tty0_pipes(ct)

        cmd = [
          OsCtld.bin('osctld-ct-wrapper'),
          "#{ct.pool.name}:#{ct.id}",
          in_pipe, out_pipe,
          'lxc-start',
          '-P', ct.lxc_home,
          '-n', ct.id,
          '-o', ct.log_path,
          '-F'
        ]

        mkfifo(in_pipe, 'w')
        mkfifo(out_pipe, 'r')

        [in_pipe, out_pipe].each do |pipe|
          File.chown(0, ct.user.ugid, pipe)
        end

        File.chmod(0640, in_pipe)
        File.chmod(0660, out_pipe)

        progress('Starting container')
        pid = Process.fork do
          in_r = File.open(in_pipe, 'r')
          out_w = File.open(out_pipe, 'w')

          STDIN.reopen(in_r)
          STDOUT.reopen(out_w)
          STDERR.reopen(out_w)

          SwitchUser.switch_to(
            ct.user.sysusername,
            ct.user.ugid,
            ct.user.homedir,
            ct.cgroup_path
          )
          Process.spawn(*cmd, pgroup: true)
        end

        in_w = File.open(in_pipe, 'w')
        out_r = File.open(out_pipe, 'r')

        progress('Connecting console')
        Console.connect_tty0(ct, pid, in_w, out_r)
        Process.wait(pid)
        ok
      end
    end

    protected
    def mkfifo(path, mode)
      syscmd("mkfifo \"#{path}\"") unless File.exist?(path)
    end
  end
end
