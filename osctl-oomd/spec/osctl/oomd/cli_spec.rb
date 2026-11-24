# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsCtl::Oomd::Cli do
  subject(:cli) { described_class.new }

  describe '#parse' do
    it 'returns the documented defaults' do
      options = cli.send(:parse, [])

      expect(options).to include(
        'interval' => 5,
        'cpu_percent' => 90,
        'memory_percent' => 95,
        'load_multiplier' => 2.0,
        'load_top' => 5,
        'restart_after_seconds' => 90,
        'stop_after_seconds' => 600,
        'export_file' => '/run/metrics/osctl-oomd.prom',
        'verbose' => false
      )
    end

    it 'merges config file values into the parsed options' do
      with_tmpdir do |dir|
        config_path = File.join(dir, 'config.yml')
        File.write(
          config_path,
          OsCtl::Lib::ConfigFile.dump_yaml(
            'interval' => 15,
            'cpu_percent' => 85,
            'dry_run' => true
          )
        )

        options = cli.send(:parse, ['--config', config_path])

        expect(options['interval']).to eq(15)
        expect(options['cpu_percent']).to eq(85)
        expect(options['dry_run']).to be(true)
      end
    end

    it 'lets explicit cli options override config file values' do
      with_tmpdir do |dir|
        config_path = File.join(dir, 'config.yml')
        File.write(
          config_path,
          OsCtl::Lib::ConfigFile.dump_yaml(
            'interval' => 15,
            'cpu_percent' => 80
          )
        )

        options = cli.send(:parse, ['--config', config_path, '--interval', '10', '--cpu-percent', '95'])

        expect(options['interval']).to eq(10)
        expect(options['cpu_percent']).to eq(95)
      end
    end

    it 'derives restart and stop thresholds from the final interval' do
      options = cli.send(:parse, ['--interval', '30', '--restart-unknown-expiry-seconds', '40'])

      expect(options['interval']).to eq(30)
      expect(options['restart_after_seconds']).to eq(90)
      expect(options['stop_after_seconds']).to eq(600)
    end

    it 'keeps explicit hit thresholds when the interval changes' do
      options = cli.send(
        :parse,
        ['--interval', '30', '--restart-unknown-expiry-seconds', '40', '--restart-hits', '9', '--stop-hits', '10']
      )

      expect(options['restart_after_seconds']).to eq(270)
      expect(options['stop_after_seconds']).to eq(300)
    end
  end

  it 'converts omitted legacy interval at historical15s, independently of new5s polling' do
    options = cli.send(:parse, ['--restart-hits', '4'])
    expect(options).to include('interval' => 5, 'restart_after_seconds' => 60, 'stop_after_seconds' => 600)
  end

  it 'rejects conflicts, nonpositive durations, invalid booleans and expiry equality' do
    [
      %w[--interval 0], %w[--interval 25],
      %w[--interval 30 --restart-unknown-expiry-seconds 35],
      %w[--restart-hits 4 --restart-after-seconds 90],
      %w[--stop-hits 4 --stop-after-seconds 600],
      %w[--load-enable yes], %w[--rtnl-enable 1], %w[--rtnl-sustain-seconds 0],
      %w[--restart-after-seconds -1]
    ].each { |args| expect { cli.send(:parse, args) }.to raise_error(ArgumentError) }
    expect(cli.send(:parse, %w[--interval 30 --restart-unknown-expiry-seconds 40])).to include('restart_after_seconds' => 90)
  end

  describe '#run' do
    it 'delegates the parsed values to Watcher.run' do
      allow(OsCtl::Lib::Logger).to receive(:setup)
      allow(OsCtl::Oomd::Watcher).to receive(:run)
      stub_const(
        'ARGV',
        %w[
          --interval 10
          --cpu-percent 80
          --memory-percent 70
          --load-multiplier 1.5
          --load-top 3
          --restart-hits 11
          --stop-hits 22
          --dry-run
          --verbose
        ]
      )

      cli.run

      expect(OsCtl::Oomd::Watcher).to have_received(:run).with(
        interval: 10,
        cpu_percent: 80,
        memory_percent: 70,
        load_multiplier: 1.5,
        load_top: 3,
        restart_after_seconds: 110,
        stop_after_seconds: 220,
        load_enable: true,
        restart_unknown_expiry_seconds: 30,
        export_file: '/run/metrics/osctl-oomd.prom',
        dry_run: true,
        verbose: true,
        rtnl_watchdog: OsCtl::Oomd::Controller::DEFAULTS
      )
    end
  end
end
