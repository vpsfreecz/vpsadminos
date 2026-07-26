require 'libosctl'
require 'json'

module OsCtld
  class Cli::Runner
    def self.run
      ret = nil

      unless ARGV.empty?
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
        pool: cfg[:pool],
        id: cfg[:id],
        lxc_home: cfg[:lxc_home],
        user_home: cfg[:user_home],
        log_file: cfg[:log_file],
        run_id: cfg[:run_id],
        lxc_config: cfg[:lxc_config],
        stdin:,
        stdout:,
        stderr:
      )
      val = runner.execute(*cfg[:args], **cfg[:kwargs])
      ret.puts(val.to_json)
    rescue Exception => e # rubocop:disable Lint/RescueException
      raise unless ret

      warn(
        "osctld-ct-runner failed: #{e.class}: #{e.message}\n" \
        "#{Array(e.backtrace).join("\n")}"
      )
      ret.puts({
        status: false,
        message: "user runner raised #{e.class}: #{e.message}",
        user_runner: true
      }.to_json)
    end
  end
end
