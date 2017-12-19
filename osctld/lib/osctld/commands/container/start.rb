module OsCtld
  class Commands::Container::Start < Commands::Base
    handle :ct_start

    include Utils::Log
    include Utils::System
    include Utils::SwitchUser

    def execute
      ct = ContainerList.find(opts[:id]) || (raise 'container not found')
      ct.exclusively do
        in_pipe, out_pipe = Console.tty0_pipes(ct.id)

        cmd = [
          OsCtld.bin('osctld-ct-wrapper'),
          in_pipe, out_pipe,
          'lxc-start',
          '-P', ct.user.lxc_home,
          '-n', ct.id,
          '-F'
        ]

        mkfifo(in_pipe, 'w')
        mkfifo(out_pipe, 'r')

        [in_pipe, out_pipe].each do |pipe|
          File.chown(0, ct.user.ugid, pipe)
        end

        File.chmod(0640, in_pipe)
        File.chmod(0660, out_pipe)

        pid = Process.fork do
          in_r = File.open(in_pipe, 'r')
          out_w = File.open(out_pipe, 'w')

          STDIN.reopen(in_r)
          STDOUT.reopen(out_w)
          STDERR.reopen(out_w)

          SwitchUser.switch_to(ct.user.name, ct.user.username, ct.user.ugid, ct.user.homedir)
          Process.spawn(*cmd, pgroup: true)
        end

        in_w = File.open(in_pipe, 'w')
        out_r = File.open(out_pipe, 'r')

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
