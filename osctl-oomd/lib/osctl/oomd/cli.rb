require 'osctl/oomd'
require 'libosctl'
require 'optparse'

module OsCtl::Oomd
  class Cli
    def self.run
      new.run
    end

    def run
      Thread.abort_on_exception = true
      OsCtl::Lib::Logger.setup(:stdout)

      options = parse(ARGV)

      Watcher.run(
        interval: options['interval'],
        cpu_percent: options['cpu_percent'],
        memory_percent: options['memory_percent'],
        load_multiplier: options['load_multiplier'],
        load_top: options['load_top'],
        restart_hits: options['restart_hits'],
        stop_hits: options['stop_hits'],
        export_file: options['export_file'],
        dry_run: options['dry_run'],
        verbose: options['verbose']
      )
    end

    protected

    def parse(args)
      options = {
        'interval' => 15,
        'cpu_percent' => 90,
        'memory_percent' => 95,
        'load_multiplier' => 2.0,
        'load_top' => 5,
        'export_file' => '/run/metrics/osctl-oomd.prom',
        'verbose' => false
      }
      explicit_restart_hits = false
      explicit_stop_hits = false

      parser = OptionParser.new do |opts|
        opts.banner = "Usage: #{$0} [options]"

        opts.on('-c', '--config FILE', 'Config file') do |v|
          cfg = OsCtl::Lib::ConfigFile.load_yaml_file(v)
          explicit_restart_hits ||= cfg.has_key?('restart_hits')
          explicit_stop_hits ||= cfg.has_key?('stop_hits')
          options.update(cfg)
        end

        opts.on('--interval RATE', Integer, 'Interval in which container statuses are checked, in seconds') do |v|
          options['interval'] = v
        end

        opts.on('--cpu-percent CPU', Integer, 'Target containers with CPU usage over N% of its limit') do |v|
          options['cpu_percent'] = v
        end

        opts.on('--memory-percent MEMORY', Integer, 'Target containers with memory usage over N% of its limit') do |v|
          options['memory_percent'] = v
        end

        opts.on('--load-multiplier LOAD', Float, "Enable OOMd when host's 1 minute load exceeds multiplied median value") do |v|
          options['load_multiplier'] = v
        end

        opts.on('--load-top TOP', Integer, 'Target container must be within N containers with highest load') do |v|
          options['load_top'] = v
        end

        opts.on('--restart-hits HITS', Integer, 'Containers with N hits are restarted') do |v|
          explicit_restart_hits = true
          options['restart_hits'] = v
        end

        opts.on('--stop-hits HITS', Integer, 'Containers with N hits are stopped') do |v|
          explicit_stop_hits = true
          options['stop_hits'] = v
        end

        opts.on('-d', '--dry-run', 'Only log what would happen, do not kill') do
          options['dry_run'] = true
        end

        opts.on('-v', '--verbose', 'Enable verbose output') do
          options['verbose'] = true
        end
      end

      if parser.parse!(args).any?
        warn parser
        exit(false)
      end

      options['restart_hits'] = 120 / options.fetch('interval') unless explicit_restart_hits
      options['stop_hits'] = 600 / options.fetch('interval') unless explicit_stop_hits

      options
    end
  end
end
