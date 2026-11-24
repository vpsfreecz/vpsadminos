# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsCtl::Cli::Top::Main do
  def cmd(args: [], opts: {}, gopts: {})
    build_command(described_class, args:, opts:, gopts:)
  end

  it 'uses the tui when json is disabled and forwards process mode' do
    model = instance_double(OsCtl::Cli::Top::PartialModel, setup: nil)
    tui = instance_double(OsCtl::Cli::Top::Tui, start: nil)
    allow(OsCtl::Cli::Top::PartialModel).to receive(:new).with(json: false, enable_netif: true,
                                                               enable_zfs: true, enable_iostat: true).and_return(model)
    allow(OsCtl::Cli::Top::Tui).to receive(:new).with(model, 2, enable_procs: false).and_return(tui)

    cmd(opts: { iostat: true, rate: 2, processes: false }).start

    expect(tui).to have_received(:start)
  end

  it 'selects the combined JSON projection before taking the seed sample' do
    model = instance_double(OsCtl::Cli::Top::PartialModel)
    exporter = instance_double(OsCtl::Cli::Top::JsonExporter)
    expect(OsCtl::Cli::Top::PartialModel).to receive(:new).with(json: true, enable_netif: true,
                                                                enable_zfs: true, enable_iostat: true).ordered.and_return(model)
    expect(model).to receive(:setup).ordered
    expect(OsCtl::Cli::Top::JsonExporter).to receive(:new).with(model, 2).ordered.and_return(exporter)
    expect(exporter).to receive(:start).ordered
    expect(model).to receive(:stop).ordered
    cmd(opts: { rate: 2 }, gopts: { json: true }).start
  end

  it 'rejects zero refresh rate' do
    expect do
      cmd(opts: { iostat: true, rate: 0, processes: false }).start
    end.to raise_error(GLI::BadCommandLine, 'rate must be a positive finite number')
  end

  it 'rejects infinite refresh rate' do
    expect do
      cmd(opts: { iostat: true, rate: Float::INFINITY, processes: false }).start
    end.to raise_error(GLI::BadCommandLine, 'rate must be a positive finite number')
  end

  it 'passes independent generic collector controls to the common model' do
    model = instance_double(OsCtl::Cli::Top::PartialModel, setup: nil, stop: nil)
    exporter = instance_double(OsCtl::Cli::Top::JsonExporter, start: nil)
    expect(OsCtl::Cli::Top::PartialModel).to receive(:new).with(json: true, enable_netif: false, enable_zfs: false, enable_iostat: true).and_return(model)
    allow(OsCtl::Cli::Top::JsonExporter).to receive(:new).and_return(exporter)
    cmd(opts: { netif: false, zfs: false, iostat: true, rate: 15 }, gopts: { json: true }).start
  end

  it 'skips collector startup and the seed sweep when monitor start loses coverage' do
    r, w = IO.pipe
    subscriber = instance_double(OsCtl::Client, open: nil)
    allow(subscriber).to receive(:cmd_data!).with(:event_subscribe).and_return('subscribed')
    allow(subscriber).to receive(:response!) { r.read }
    allow(subscriber).to receive(:close) { r.close }
    primary = FakeClientHelpers::ClientDouble.new(cmd_data: { ct_list: [[]], pool_list: [[{ name: 'tank' }]] })
    stub_osctld_clients(subscriber, primary)
    allow(OsCtl::Lib::CGroup).to receive(:v1?).and_return(false)
    model = OsCtl::Cli::Top::PartialModel.new(enable_netif: false)
    monitor = model.send(:monitor)
    allow(monitor).to receive(:process_saved_events).and_raise(ArgumentError, 'bad saved event')
    expect(model.send(:iostat)).not_to receive(:start)
    expect(model).not_to receive(:measure)

    expect { model.setup }.to raise_error(OsCtl::Cli::Top::PartialModel::MonitorLost, /lost osctld event coverage/)
  ensure
    w&.close
    model&.stop
  end

  it 'reports monitor loss on stderr with exit status 1 and stops the model' do
    model = instance_double(OsCtl::Cli::Top::PartialModel, setup: nil, stop: nil)
    allow(OsCtl::Cli::Top::PartialModel).to receive(:new).and_return(model)
    exporter = instance_double(OsCtl::Cli::Top::JsonExporter)
    allow(OsCtl::Cli::Top::JsonExporter).to receive(:new).and_return(exporter)
    error = OsCtl::Cli::Top::PartialModel::MonitorLost.new('ct top: lost osctld event coverage; restart the sampler')
    allow(exporter).to receive(:start).and_raise(error)

    expect do
      expect(OsCtl::Cli::App.get.run(%w[-j ct top])).to eq(1)
    end.to output(/\Aerror: ct top: lost osctld event coverage; restart the sampler\n\z/).to_stderr_from_any_process
       .and output('').to_stdout_from_any_process
    expect(model).to have_received(:stop).once
  end
end
