# frozen_string_literal: true

require 'rbconfig'
require 'spec_helper'

RSpec.describe OsCtl::Oomd::Killer do
  describe OsCtl::Oomd::Killer::Container do
    subject(:container) { described_class.new('tank', 'ct1') }

    it 'increments hit counters and timestamps on hit' do
      allow(Time).to receive(:now).and_return(Time.at(1), Time.at(2))

      container.hit

      expect(container.restart_hits).to eq(1)
      expect(container.stop_hits).to eq(1)
      expect(container.first_hit).to eq(Time.at(1))
      expect(container.last_hit).to eq(Time.at(2))
    end

    it 'decrements counters on miss without going below zero' do
      container.hit
      container.miss
      container.miss

      expect(container.restart_hits).to eq(0)
      expect(container.stop_hits).to eq(0)
    end

    it 'resets only restart hits' do
      container.hit
      container.reset_restart_hits

      expect(container.restart_hits).to eq(0)
      expect(container.stop_hits).to eq(1)
    end

    it 'resets only stop hits' do
      container.hit
      container.reset_stop_hits

      expect(container.restart_hits).to eq(1)
      expect(container.stop_hits).to eq(0)
    end
  end

  describe '#watched?' do
    it 'is false for unknown containers' do
      killer = described_class.new(restart_hits: 2, stop_hits: 3, dry_run: false)

      expect(killer.watched?('tank', 'missing')).to be(false)
    end
  end

  describe '#export' do
    it 'returns clones of tracked containers' do
      killer = described_class.new(restart_hits: 2, stop_hits: 3, dry_run: false)
      container = OsCtl::Oomd::Killer::Container.new('tank', 'ct1')
      container.hit
      killer.instance_variable_get(:@containers)['tank:ct1'] = container

      exported = killer.export.first

      expect(exported).not_to be(container)
      expect(exported.pool).to eq('tank')
      expect(exported.id).to eq('ct1')
      expect(exported.restart_hits).to eq(1)
    end
  end

  describe '#determine_action' do
    it 'prefers stop when both thresholds are met' do
      killer = described_class.new(restart_hits: 2, stop_hits: 3, dry_run: false)
      container = OsCtl::Oomd::Killer::Container.new('tank', 'ct1')
      3.times { container.hit }

      expect(killer.send(:determine_action, container)).to eq(:stop)
    end
  end

  describe '#take_action' do
    it 'does not call external commands in dry-run mode' do
      killer = described_class.new(restart_hits: 2, stop_hits: 3, dry_run: true)
      container = OsCtl::Oomd::Killer::Container.new('tank', 'ct1')
      container.hit
      killer.instance_variable_get(:@containers)['tank:ct1'] = container

      allow(OsCtl::Lib::Logger).to receive(:log)
      allow(Kernel).to receive(:system)
      allow(IO).to receive(:pipe)
      allow(Process).to receive(:spawn)

      killer.send(:take_action, 'tank', 'ct1', :restart)

      expect(Kernel).not_to have_received(:system)
      expect(IO).not_to have_received(:pipe)
      expect(Process).not_to have_received(:spawn)
    end

    it 'broadcasts successful actions and resets only the matching hit counter' do
      killer = described_class.new(restart_hits: 2, stop_hits: 5, dry_run: false)
      container = OsCtl::Oomd::Killer::Container.new('tank', 'ct1')
      2.times { container.hit }
      killer.instance_variable_get(:@containers)['tank:ct1'] = container

      actual_spawn = Process.method(:spawn)
      read_pipe = instance_double(IO, close: nil)
      write_pipe = instance_double(IO, close: nil)
      payloads = []

      allow(OsCtl::Lib::Logger).to receive(:log)
      allow(Kernel).to receive(:system).with('osctl', 'ct', 'restart', '--kill', 'tank:ct1').and_return(true)
      allow(IO).to receive(:pipe).and_return([read_pipe, write_pipe])
      allow(write_pipe).to receive(:puts) { |line| payloads << line }
      allow(Process).to receive(:spawn) do |*args, **_kwargs|
        expect(args).to eq(%w[osctl event broadcast])
        actual_spawn.call(RbConfig.ruby, '-e', 'exit 0')
      end

      killer.send(:take_action, 'tank', 'ct1', :restart)

      expect(JSON.parse(payloads.first)).to include(
        'events' => [
          include(
            'type' => 'osctl_oomd',
            'opts' => include(
              'pool' => 'tank',
              'id' => 'ct1',
              'action' => 'restart'
            )
          )
        ]
      )
      expect(container.restart_hits).to eq(0)
      expect(container.stop_hits).to eq(2)
    end

    it 'logs failed osctl execution and keeps counters intact' do
      killer = described_class.new(restart_hits: 2, stop_hits: 5, dry_run: false)
      container = OsCtl::Oomd::Killer::Container.new('tank', 'ct1')
      2.times { container.hit }
      killer.instance_variable_get(:@containers)['tank:ct1'] = container

      logged = []
      allow(Kernel).to receive(:system).and_return(false)
      allow(OsCtl::Lib::Logger).to receive(:log) do |level, message|
        logged << [level, message]
      end

      killer.send(:take_action, 'tank', 'ct1', :restart)

      expect(logged).to include([:warn, '[killer] osctl ct restart tank:ct1 failed'])
      expect(container.restart_hits).to eq(2)
      expect(container.stop_hits).to eq(2)
    end
  end
end
