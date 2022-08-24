module OsCtl
  module Cli::Devices
    DEVICES_FIELDS = %i(
      type
      major
      minor
      mode
      name
      inherit
      inherited
    )

    def do_device_list(cmd, cmd_opts)
      if opts[:list]
        puts DEVICES_FIELDS.join("\n")
        return
      end

      fmt_opts = {
        layout: :columns,
        cols: opts[:output] ? opts[:output].split(',').map(&:to_sym) : nil,
      }
      fmt_opts[:header] = false if opts['hide-header']

      osctld_fmt(
        cmd,
        cmd_opts: cmd_opts,
        fmt_opts: fmt_opts,
      )
    end

    def do_device_add(cmd, cmd_opts)
      unless %w(char block).include?(args[1])
        raise GLI::BadCommandLine, 'device type has to be one of: block, char'
      end

      osctld_fmt(cmd, cmd_opts: cmd_opts.merge(
        type: args[1],
        major: args[2],
        minor: args[3],
        mode: args[4],
        dev_name: args[5],
        inherit: opts[:inherit],
        parents: opts[:parents]
      ))
    end

    def do_device_delete(cmd, cmd_opts)
      unless %w(char block).include?(args[1])
        raise GLI::BadCommandLine, 'device type has to be one of: block, char'
      end

      osctld_fmt(cmd, cmd_opts: cmd_opts.merge(
        type: args[1],
        major: args[2],
        minor: args[3],
        recursive: opts[:recursive]
      ))
    end

    def do_device_chmod(cmd, cmd_opts)
      unless %w(char block).include?(args[1])
        raise GLI::BadCommandLine, 'device type has to be one of: block, char'
      end

      osctld_fmt(cmd, cmd_opts: cmd_opts.merge(
        type: args[1],
        major: args[2],
        minor: args[3],
        mode: args[4] == '-' ? '' : args[4],
        parents: opts[:parents],
        recursive: opts[:recursive]
      ))
    end

    def do_device_promote(cmd, cmd_opts)
      unless %w(char block).include?(args[1])
        raise GLI::BadCommandLine, 'device type has to be one of: block, char'
      end

      osctld_fmt(cmd, cmd_opts: cmd_opts.merge(
        type: args[1],
        major: args[2],
        minor: args[3],
      ))
    end

    def do_device_inherit(cmd, cmd_opts)
      unless %w(char block).include?(args[1])
        raise GLI::BadCommandLine, 'device type has to be one of: block, char'
      end

      osctld_fmt(cmd, cmd_opts: cmd_opts.merge(
        type: args[1],
        major: args[2],
        minor: args[3],
      ))
    end

    def do_device_set_inherit(cmd, cmd_opts)
      unless %w(char block).include?(args[1])
        raise GLI::BadCommandLine, 'device type has to be one of: block, char'
      end

      osctld_fmt(cmd, cmd_opts: cmd_opts.merge(
        type: args[1],
        major: args[2],
        minor: args[3],
      ))
    end

    def do_device_unset_inherit(cmd, cmd_opts)
      unless %w(char block).include?(args[1])
        raise GLI::BadCommandLine, 'device type has to be one of: block, char'
      end

      osctld_fmt(cmd, cmd_opts: cmd_opts.merge(
        type: args[1],
        major: args[2],
        minor: args[3],
      ))
    end

    def do_device_replace(cmd, cmd_opts)
      osctld_fmt(cmd, cmd_opts: cmd_opts.merge(
        devices: JSON.parse(STDIN.read)['devices'],
      ))
    end
  end
end
