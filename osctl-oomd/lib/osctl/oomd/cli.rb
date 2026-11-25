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
        restart_after_seconds: options['restart_after_seconds'],
        stop_after_seconds: options['stop_after_seconds'],
        load_enable: options['load_enable'],
        restart_unknown_expiry_seconds: options['restart_unknown_expiry_seconds'],
        export_file: options['export_file'],
        dry_run: options['dry_run'],
        verbose: options['verbose'],
        rtnl_watchdog: options['rtnl_watchdog'],
        rtnl_exposure: options['rtnl_exposure']
      )
    end

    protected

    def boolean(value)
      return true if value == 'true'
      return false if value == 'false'

      raise ArgumentError, 'boolean must be true or false'
    end

    def parse(args)
      options = {
        'interval' => 5,
        'load_enable' => true,
        'restart_after_seconds' => 90,
        'stop_after_seconds' => 600,
        'restart_unknown_expiry_seconds' => 30,
        'cpu_percent' => 90,
        'memory_percent' => 95,
        'load_multiplier' => 2.0,
        'load_top' => 5,
        'export_file' => '/run/metrics/osctl-oomd.prom',
        'verbose' => false
      }
      supplied = {}

      parser = OptionParser.new do |opts|
        opts.banner = "Usage: #{$0} [options]"

        opts.on('-c', '--config FILE', 'Config file') do |v|
          cfg = OsCtl::Lib::ConfigFile.load_yaml_file(v)
          raise ArgumentError, 'configuration must be an object' unless cfg.is_a?(Hash)

          cfg.each { |key, value| supplied[key] = true unless value.nil? }
          options.update(cfg)
        end

        opts.on('--interval RATE', Integer, 'Interval in which container statuses are checked, in seconds') do |v|
          supplied['interval'] = true
          options['interval'] = v
        end

        opts.on('--load-enable BOOL', 'Enable the median load gate (true or false)') do |v|
          options['load_enable'] = boolean(v)
        end
        %w[restart_after_seconds stop_after_seconds restart_unknown_expiry_seconds].each do |key|
          opts.on("--#{key.tr('_', '-')} SECONDS", Integer, key.tr('_', ' ')) do |v|
            supplied[key] = true
            options[key] = v
          end
        end
        opts.on('--rtnl-enable BOOL', 'Enable sustained RTNL gating (true or false)') do |v|
          options['rtnl_watchdog'] = (options['rtnl_watchdog'] || {}).merge('enable' => boolean(v))
        end
        opts.on('--rtnl-exposure-enable BOOL', 'Collect independent qualified RTNL exposure (true or false)') do |v|
          options['rtnl_exposure'] = (options['rtnl_exposure'] || {}).merge('enable' => boolean(v))
        end
        %w[latency_threshold_ms sustain_seconds pending_seconds].each do |key|
          opts.on("--rtnl-#{key.tr('_', '-')} N", Integer, "RTNL #{key.tr('_', ' ')}") do |v|
            options['rtnl_watchdog'] = (options['rtnl_watchdog'] || {}).merge(key => v)
          end
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
          supplied['restart_hits'] = true
          options['restart_hits'] = v
        end

        opts.on('--stop-hits HITS', Integer, 'Containers with N hits are stopped') do |v|
          supplied['stop_hits'] = true
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

      options.reject! { |key, value| value.nil? && %w[interval restart_after_seconds stop_after_seconds].include?(key) }
      options['interval'] ||= 5
      options['restart_after_seconds'] ||= 90
      options['stop_after_seconds'] ||= 600
      options['rtnl_watchdog'] = Controller.settings(options['rtnl_watchdog'])
      options['rtnl_exposure'] = RtnlExposure.settings(options['rtnl_exposure'])

      %w[restart stop].each do |kind|
        old = "#{kind}_hits"
        current = "#{kind}_after_seconds"
        next unless supplied[old]

        raise ArgumentError, "#{old} conflicts with #{current}" if supplied[current]
        raise ArgumentError, "invalid #{old}" unless options[old].is_a?(Integer) && options[old] > 0

        legacy_interval = supplied['interval'] ? options['interval'] : 15
        options[current] = options.delete(old) * legacy_interval
        warn "#{old} is deprecated; use #{current}=#{options[current]} (seconds)"
      end
      %w[interval restart_after_seconds stop_after_seconds restart_unknown_expiry_seconds].each do |key|
        raise ArgumentError, "#{key} must be a positive integer" unless options[key].is_a?(Integer) && options[key] > 0
      end
      unless options['load_multiplier'].is_a?(Numeric) && options['load_multiplier'].finite? && options['load_multiplier'] > 0
        raise ArgumentError, 'load_multiplier must be positive and finite'
      end
      unless [true, false].include?(options['load_enable'])
        raise ArgumentError, 'load_enable must be boolean'
      end
      unless options['restart_unknown_expiry_seconds'] > options['interval'] + options['rtnl_watchdog']['observation_max_age_seconds']
        raise ArgumentError, 'restart_unknown_expiry_seconds must exceed interval + observation_max_age_seconds'
      end

      options
    end
  end
end
