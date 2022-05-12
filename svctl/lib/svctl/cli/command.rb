require 'libosctl'

module SvCtl
  class Cli::Command < OsCtl::Lib::Cli::Command
    def self.run(method)
      Proc.new do |global_opts, opts, args|
        cmd = new(global_opts, opts, args)
        cmd.method(method).call
      end
    end

    def list_all
      all_runlevels = SvCtl.runlevels

      SvCtl.all_services.sort.each do |s|
        sv_runlevels = s.runlevels
        rlv_line = all_runlevels.map do |rlv|
          sprintf('%-10s', sv_runlevels.include?(rlv) ? rlv : '')
        end.join('  ')

        puts sprintf('%-20s    %s', s.name, rlv_line)
      end
    end

    def list_services
      if opts[:all]
        require_args!
        list_all

      else
        require_args!(optional: %w(runlevel))

        SvCtl.runlevel_services(args[0] || 'current').each do |s|
          puts s.name
        end
      end
    end

    def enable
      require_args!('service', optional: %w(runlevel))
      SvCtl.enable(args[0], args[1] || 'current')
    end

    def disable
      require_args!('service', optional: %w(runlevel))
      SvCtl.disable(args[0], args[1] || 'current')
    end

    def list_runlevels
      require_args!
      SvCtl.runlevels.each { |v| puts v }
    end

    def runlevel
      require_args!
      puts SvCtl.runlevel
    end

    def switch
      require_args!('runlevel')
      SvCtl.switch(args[0])
    end

    def gen_bash_completion
      c = OsCtl::Lib::Cli::Completion::Bash.new(Cli::App.get)

      services = 'ls -1 /etc/runit/services'
      runlevels = 'ls -1 /etc/runit/runsvdir | grep -v previous'

      c.arg(cmd: :all, name: :service, expand: services)
      c.arg(cmd: :all, name: :runlevel, expand: runlevels)

      puts c.generate
    end
  end
end
