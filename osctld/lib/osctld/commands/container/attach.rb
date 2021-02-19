require 'osctld/commands/base'

module OsCtld
  class Commands::Container::Attach < Commands::Base
    handle :ct_attach

    include OsCtl::Lib::Utils::Log
    include Utils::SwitchUser

    Shell = Struct.new(:type, :executable)

    def execute
      ct = DB::Containers.find(opts[:id], opts[:pool])
      error!('container not found') unless ct
      error!('container not running') if ct.state != :running

      base_args = [
        'lxc-attach', '-P', ct.lxc_home,
        '-n', ct.id,
        '--clear-env',
        '--keep-var', 'TERM',
        '-v', 'USER=root',
        '-v', 'LOGNAME=root',
        '-v', 'HOME=/root',
        '-v', "PATH=#{SwitchUser::SYSTEM_PATH.join(':')}",
        '-v', 'HISTFILE=/root/.osctl_ct_attach_history',
      ]

      if opts[:user_shell]
        ok(ct_attach(ct, *base_args))

      else
        shell = find_shell(ct)
        error!('no supported shell located') unless shell

        ok(ct_attach(
          ct,
          *base_args,
          '--keep-var', 'LANG',
          '-v', "PS1=#{prompt(ct, shell)}",
          '--',
          *shell_args(shell)
        ))
      end
    end

    protected
    def find_shell(ct)
      rootfs = File.join('/proc', ct.init_pid.to_s, 'root')

      %i(bash busybox sh).each do |type|
        path = DistConfig.run(ct.get_run_conf, :bin_path)

        begin
          File.lstat(File.join(rootfs, path, type.to_s))

        rescue Errno::ENOENT
          next
        end

        return Shell.new(type, File.join(path, type.to_s))
      end

      nil
    end

    def shell_args(shell)
      case shell.type
      when :bash
        [shell.executable, '--norc']

      when :busybox
        [shell.executable, 'sh']

      when :sh
        [shell.executable]
      end
    end

    def prompt(ct, shell)
      case shell.type
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
