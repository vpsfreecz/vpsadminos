# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsCtl::Oomd::Cli do
  subject(:cli) { described_class.new }

  describe '#parse' do
    it 'returns the documented defaults' do
      options = cli.send(:parse, [])

      expect(options).to include(
        'interval' => 15,
        'cpu_percent' => 90,
        'memory_percent' => 95,
        'load_multiplier' => 2.0,
        'load_top' => 5,
        'restart_hits' => 8,
        'stop_hits' => 40,
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
            'interval' => 30,
            'cpu_percent' => 85,
            'dry_run' => true
          )
        )

        options = cli.send(:parse, ['--config', config_path])

        expect(options['interval']).to eq(30)
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
            'interval' => 30,
            'cpu_percent' => 80
          )
        )

        options = cli.send(:parse, ['--config', config_path, '--interval', '10', '--cpu-percent', '95'])

        expect(options['interval']).to eq(10)
        expect(options['cpu_percent']).to eq(95)
      end
    end

    it 'derives restart and stop thresholds from the final interval' do
      options = cli.send(:parse, ['--interval', '30'])

      expect(options['interval']).to eq(30)
      expect(options['restart_hits']).to eq(4)
      expect(options['stop_hits']).to eq(20)
    end

    it 'keeps explicit hit thresholds when the interval changes' do
      options = cli.send(
        :parse,
        ['--interval', '30', '--restart-hits', '9', '--stop-hits', '10']
      )

      expect(options['restart_hits']).to eq(9)
      expect(options['stop_hits']).to eq(10)
    end
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
        restart_hits: 11,
        stop_hits: 22,
        export_file: '/run/metrics/osctl-oomd.prom',
        dry_run: true,
        verbose: true
      )
    end
  end
end
