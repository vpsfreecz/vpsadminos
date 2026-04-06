# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsCtl::Oomd::Watcher do
  def build_watcher(queue:, host_load:, killer:, exporter:)
    allow(OsCtl::Oomd::HostLoad).to receive(:new).and_return(host_load)
    allow(OsCtl::Oomd::Killer).to receive(:new).and_return(killer)
    allow(OsCtl::Oomd::Exporter).to receive(:new).and_return(exporter)
    allow(OsCtl::Lib::Queue).to receive(:new).and_return(queue)

    described_class.new(
      interval: 15,
      cpu_percent: 90,
      memory_percent: 95,
      load_multiplier: 2.0,
      load_top: 2,
      restart_hits: 8,
      stop_hits: 40,
      export_file: '/tmp/oomd.prom'
    )
  end

  def host_load_double
    instance_double(OsCtl::Oomd::HostLoad, median: 10)
  end

  def killer_double
    instance_double(
      OsCtl::Oomd::Killer,
      start: nil,
      add_hit: nil,
      add_miss: nil,
      watched?: false
    )
  end

  def exporter_double
    instance_double(OsCtl::Oomd::Exporter, start: nil)
  end

  def ranked_containers
    [
      { 'pool' => 'tank', 'id' => 'ct1', 'loadavg' => [10] },
      { 'pool' => 'tank', 'id' => 'ct2', 'loadavg' => [5] },
      { 'pool' => 'tank', 'id' => 'ct3', 'loadavg' => [1] }
    ]
  end

  def sample_container
    {
      'pool' => 'tank',
      'id' => 'ct1',
      'loadavg' => [25],
      'memory_limit' => 1000,
      'memory' => 980,
      'cpu_limit' => nil,
      'cpu_usage' => 0
    }
  end

  describe '#hit?' do
    it 'rejects containers without memory limits' do
      watcher = build_watcher(
        queue: instance_double(OsCtl::Lib::Queue),
        host_load: host_load_double,
        killer: killer_double,
        exporter: exporter_double
      )
      ranked = ranked_containers
      ct = ranked.first.merge('memory_limit' => nil, 'memory' => 900, 'cpu_limit' => 100, 'cpu_usage' => 95)

      expect(watcher.hit?(ct, ranked)).to be(false)
    end

    it 'rejects containers below the memory threshold' do
      watcher = build_watcher(
        queue: instance_double(OsCtl::Lib::Queue),
        host_load: host_load_double,
        killer: killer_double,
        exporter: exporter_double
      )
      ranked = ranked_containers
      ct = ranked.first.merge('memory_limit' => 1000, 'memory' => 900, 'cpu_limit' => 100, 'cpu_usage' => 95)

      expect(watcher.hit?(ct, ranked)).to be(false)
    end

    it 'rejects containers below the cpu threshold when cpu is limited' do
      watcher = build_watcher(
        queue: instance_double(OsCtl::Lib::Queue),
        host_load: host_load_double,
        killer: killer_double,
        exporter: exporter_double
      )
      ranked = ranked_containers
      ct = ranked.first.merge('memory_limit' => 1000, 'memory' => 980, 'cpu_limit' => 100, 'cpu_usage' => 80)

      expect(watcher.hit?(ct, ranked)).to be(false)
    end

    it 'accepts cpu-unlimited containers when other predicates pass' do
      watcher = build_watcher(
        queue: instance_double(OsCtl::Lib::Queue),
        host_load: host_load_double,
        killer: killer_double,
        exporter: exporter_double
      )
      ranked = ranked_containers
      ct = ranked.first.merge('memory_limit' => 1000, 'memory' => 980, 'cpu_limit' => nil, 'cpu_usage' => 0)

      expect(watcher.hit?(ct, ranked)).to be(true)
    end

    it 'rejects containers outside load_top' do
      watcher = build_watcher(
        queue: instance_double(OsCtl::Lib::Queue),
        host_load: host_load_double,
        killer: killer_double,
        exporter: exporter_double
      )
      ranked = ranked_containers
      ct = ranked.last.merge('memory_limit' => 1000, 'memory' => 980, 'cpu_limit' => nil, 'cpu_usage' => 0)

      expect(watcher.hit?(ct, ranked)).to be(false)
    end
  end

  describe '#run' do
    it 'adds hits only when host load exceeds the threshold' do
      stop_error = Class.new(StandardError)
      queue = instance_double(OsCtl::Lib::Queue)
      host_load = host_load_double
      killer = killer_double
      watcher = build_watcher(queue:, host_load:, killer:, exporter: exporter_double)

      allow(host_load).to receive(:<<)
      allow(Thread).to receive(:new).and_return(instance_double(Thread))

      pop_calls = 0
      allow(queue).to receive(:pop) do
        pop_calls += 1

        case pop_calls
        when 1
          { 'loadavg' => [15], 'containers' => [sample_container] }
        when 2
          { 'loadavg' => [25], 'containers' => [sample_container] }
        else
          raise stop_error
        end
      end
      allow(watcher).to receive(:hit?).and_return(true)

      expect do
        watcher.run
      end.to raise_error(stop_error)

      expect(killer).to have_received(:add_hit).with('tank', 'ct1').once
      expect(host_load).to have_received(:<<).with(15)
      expect(host_load).to have_received(:<<).with(25)
    end

    it 'adds misses for watched containers that no longer qualify' do
      stop_error = Class.new(StandardError)
      queue = instance_double(OsCtl::Lib::Queue)
      host_load = host_load_double
      killer = killer_double
      watcher = build_watcher(queue:, host_load:, killer:, exporter: exporter_double)

      allow(host_load).to receive(:<<)
      allow(Thread).to receive(:new).and_return(instance_double(Thread))

      pop_calls = 0
      allow(queue).to receive(:pop) do
        pop_calls += 1

        case pop_calls
        when 1
          { 'loadavg' => [25], 'containers' => [sample_container] }
        else
          raise stop_error
        end
      end
      allow(watcher).to receive(:hit?).and_return(false)
      allow(killer).to receive(:watched?).with('tank', 'ct1').and_return(true)

      expect do
        watcher.run
      end.to raise_error(stop_error)

      expect(killer).to have_received(:add_miss).with('tank', 'ct1')
    end
  end
end
