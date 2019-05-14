require 'json'
require 'tempfile'

module OsCtld
  module Utils::SwitchUser
    def ct_control(ct, cmd, opts = {})
      r, w = IO.pipe

      ct_opts = {
        lxc_home: ct.lxc_home,
        user_home: ct.user.homedir,
        log_file: ct.log_path,
      }

      pid = SwitchUser.fork_and_switch_to(
        ct.user.sysusername,
        ct.user.ugid,
        ct.user.homedir,
        ct.cgroup_path,
        prlimits: ct.prlimits.export,
      ) do
        r.close

        ret = SwitchUser::ContainerControl.run(cmd, opts, ct_opts)
        w.write(ret.to_json + "\n")

        exit
      end

      w.close

      begin
        ret = JSON.parse(r.readline, symbolize_names: true)
        Process.wait(pid)
        ret

      rescue EOFError
        Process.wait(pid)
        {status: false, message: 'user runner failed'}
      end
    end

    def ct_attach(ct, *args)
      {
        cmd: ::OsCtld.bin('osctld-ct-exec'),
        args: args.map(&:to_s),
        env: Hash[ENV.select { |k,_v| k.start_with?('BUNDLE') || k.start_with?('GEM') }],
        settings: {
          user: ct.user.sysusername,
          ugid: ct.user.ugid,
          homedir: ct.user.homedir,
          cgroup_path: ct.cgroup_path,
          prlimits: ct.prlimits.export,
        },
      }
    end

    def ct_exec(ct, opts)
      if ct.running?
        ct_control(ct, :ct_exec_running, {
          id: ct.id,
          cmd: opts[:cmd],
          stdin: opts[:stdin],
          stdout: opts[:stdout],
          stderr: opts[:stderr],
        })

      elsif !ct.running? && opts[:network]
        ct.mount

        init = init_script(ct)

        begin
          ct_control(ct, :ct_exec_network, {
            id: ct.id,
            init_script: File.join('/', File.basename(init.path)),
            net_config: NetConfig.create(ct),
            cmd: opts[:cmd],
            stdin: opts[:stdin],
            stdout: opts[:stdout],
            stderr: opts[:stderr],
          })
        ensure
          unlink_file(init.path)
        end

      else
        ct_control(ct, :ct_exec_run, {
          id: ct.id,
          cmd: opts[:cmd],
          stdin: opts[:stdin],
          stdout: opts[:stdout],
          stderr: opts[:stderr],
        })
      end
    end

    def ct_runscript(ct, opts)
      script = Tempfile.create(['.runscript', '.sh'], ct.rootfs)
      script.chmod(0500)

      File.open(opts[:script], 'r') { |f| IO.copy_stream(f, script) }
      script.close

      if ct.running?
        ct_control(ct, :ct_runscript_running, {
          id: ct.id,
          script: File.join('/', File.basename(script.path)),
          stdin: opts[:stdin],
          stdout: opts[:stdout],
          stderr: opts[:stderr],
        })

      elsif !ct.running? && opts[:network]
        ct.mount

        init = init_script(ct)

        begin
          ct_control(ct, :ct_runscript_network, {
            id: ct.id,
            init_script: File.join('/', File.basename(init.path)),
            net_config: NetConfig.create(ct),
            script: File.join('/', File.basename(script.path)),
            stdin: opts[:stdin],
            stdout: opts[:stdout],
            stderr: opts[:stderr],
          })
        ensure
          unlink_file(init.path)
        end

      else
        ct_control(ct, :ct_runscript_run, {
          id: ct.id,
          script: File.join('/', File.basename(script.path)),
          stdin: opts[:stdin],
          stdout: opts[:stdout],
          stderr: opts[:stderr],
        })
      end

    ensure
      script.close
      unlink_file(script.path)
    end

    # Run a command `cmd` within container `ct`
    # @param ct [Container]
    # @param cmd [String] command to execute in shell
    # @param opts [Hash] options
    # @option opts [IO] :stdin
    # @option opts [IO] :stdout
    # @option opts [IO] :stderr
    # @option opts [Boolean] :run run the container if it is stopped?
    # @option opts [Boolean] :network setup network if the container is run?
    # @option opts [Array<Integer>, Symbol] :valid_rcs
    # @return [OsCtl::Lib::SystemCommandResult]
    def ct_syscmd(ct, cmd, opts = {})
      opts[:valid_rcs] ||= []
      log(:work, ct, cmd)

      in_r, in_w = nil
      out_r, out_w = IO.pipe

      if opts[:stdin].is_a?(String)
        in_r, in_w = IO.pipe
        in_w.write(opts[:stdin])
        in_w.close

      elsif opts[:stdin]
        in_r = opts[:stdin]
      end

      if ct.running?
        ct_cmd = :ct_exec_running

      elsif opts[:run] && opts[:network]
        ct_cmd = :ct_exec_network

      elsif opts[:run]
        ct_cmd = :ct_exec_run

      else
        raise OsCtld::SystemCommandFailed, 'Container is not running'
      end

      ret = ct_control(ct, ct_cmd, {
        id: ct.id,
        cmd: cmd,
        stdin: in_r,
        stdout: out_w,
        stderr: out_w,
      })

      in_r.close if in_r && opts[:stdin].is_a?(String)
      out_w.close
      out = out_r.read
      out_r.close

      if !ret[:status]
        raise OsCtld::SystemCommandFailed, "Command '#{cmd}' within CT #{ct.id} failed"

      elsif ret[:output][:exitstatus] != 0 && \
            opts[:valid_rcs] != :all && \
            !opts[:valid_rcs].include?(ret[:output][:exitstatus])
        raise OsCtld::SystemCommandFailed,
              "Command '#{cmd}' within CT #{ct.id} failed with exit code "+
              "#{ret[:output][:exitstatus]}: #{out}"
      end

      OsCtl::Lib::SystemCommandResult.new(ret[:output][:exitstatus], out)
    end

    def init_script(ct)
      f = Tempfile.create(['.runscript', '.sh'], ct.rootfs)
      f.chmod(0500)
      f.puts('#!/bin/sh')
      f.puts('echo ready')
      f.puts('read _')
      f.close
      f
    end

    def unlink_file(path)
      File.unlink(path)
    rescue SystemCallError
      # pass
    end
  end
end
