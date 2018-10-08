module SvCtl
  class Cli::Command
    def self.run(method)
      Proc.new do |global_opts, opts, args|
        cmd = new(global_opts, opts, args)
        cmd.method(method).call
      end
    end

    attr_reader :gopts, :opts, :args

    def initialize(global_opts, opts, args)
      @gopts = global_opts
      @opts = opts
      @args = args
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
        list_all

      else
        SvCtl.runlevel_services(args[0] || 'current').each do |s|
          puts s.name
        end
      end
    end

    def enable
      raise GLI::BadCommandLine, 'missing argument <service>' unless args[0]
      SvCtl.enable(args[0], args[1] || 'current')
    end

    def disable
      raise GLI::BadCommandLine, 'missing argument <service>' unless args[0]
      SvCtl.disable(args[0], args[1] || 'current')
    end

    def list_runlevels
      SvCtl.runlevels.each { |v| puts v }
    end

    def runlevel
      puts SvCtl.runlevel
    end

    def switch
      raise GLI::BadCommandLine, 'missing argument <runlevel>' unless args[0]
      SvCtl.switch(args[0])
    end
  end
end
