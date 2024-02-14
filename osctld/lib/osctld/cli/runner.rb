require 'libosctl'
require 'json'

module OsCtld
  class Cli::Runner
    def self.run
      if ARGV.length > 0
        warn "Usage: #{$0}"
        exit(false)
      end

      OsCtl::Lib::Logger.setup(:none)
      CGroup.init

      cfg = JSON.parse($stdin.readline, symbolize_names: true)

      Process.setproctitle(
        "osctld: #{cfg[:pool]}:#{cfg[:id]} runner:#{cfg[:name].downcase}"
      )

      ret = IO.new(cfg[:return])
      stdin = cfg[:stdin] && IO.new(cfg[:stdin])
      stdout = IO.new(cfg[:stdout])
      stderr = IO.new(cfg[:stderr])

      [ret, stdin, stdout, stderr].compact.each do |io|
        io.close_on_exec = true
      end

      runner = OsCtld::ContainerControl::Commands.const_get(cfg[:name])::Runner.new(
        id: cfg[:id],
        lxc_home: cfg[:lxc_home],
        user_home: cfg[:user_home],
        log_file: cfg[:log_file],
        stdin:,
        stdout:,
        stderr:
      )
      val = runner.execute(*cfg[:args], **cfg[:kwargs])
      ret.puts(val.to_json)
    end
  end
end
