module OsCtld
  class Commands::Container::Attach < Commands::Base
    handle :ct_attach

    include OsCtl::Lib::Utils::Log
    include Utils::SwitchUser

    def execute
      ct = DB::Containers.find(opts[:id], opts[:pool])
      return error('container not found') unless ct

      ct.inclusively do
        next error('container not running') if ct.state != :running

        base_args = [
          'lxc-attach', '-P', ct.lxc_home,
          '-n', ct.id,
          '--clear-env',
          '--keep-var', 'TERM',
          '-v', 'USER=root',
          '-v', 'LOGNAME=root',
          '-v', 'HOME=/root',
        ]

        if opts[:user_shell]
          ok(ct_exec(ct, *base_args))

        else
          shell = find_shell(ct)
          next error('no supported shell located') unless shell

          ok(ct_exec(
            ct,
            *base_args,
            '-v', "PS1=#{prompt(ct, shell)}",
            '--',
            *shell_args(shell)
          ))
        end
      end
    end

    protected
    def find_shell(ct)
      rootfs = File.join('/proc', ct.init_pid.to_s, 'root')

      %i(bash busybox sh).detect do |shell|
        begin
          File.lstat(File.join(rootfs, '/bin', shell.to_s))
          true

        rescue Errno::ENOENT
          false
        end
      end
    end

    def shell_args(shell)
      case shell
      when :bash
        ['/bin/bash', '--norc']

      when :busybox
        ['/bin/sh']

      else
        ["/bin/#{shell}"]
      end
    end

    def prompt(ct, shell)
      case shell
      when :bash
        "\\n\\[\\033[1;31m\\][CT #{ct.id}]\\[\\033[0m\\] "+
        "\\[\\033[1;95m\\]\\u@\\h:\\w\\$\\[\\033[0m\\] "

      when :busybox
        "\\n[CT #{ct.id}] \\u@\\h:\\w\\$ "

      when :sh
        "\\n[CT #{ct.id}] $USER@$HOSTNAME:$PWD\\$ "
      end
    end
  end
end
