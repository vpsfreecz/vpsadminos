# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsCtl::Cli::Ps::Main do
  def cmd(args: [], opts: {}, gopts: {})
    build_command(described_class, args:, opts:, gopts:)
  end

  it 'uses scoped default columns and appends sort columns' do
    command = cmd(args: ['ct1'], opts: { sort: 'rss', parameter: [] }, gopts: { pool: 'tank' })
    allow(command).to receive(:get_process_list).and_return([[], { 'tank' => true }, []])
    allow(OsCtl::Cli::Ps::Columns).to receive(:generate).and_return([[], []])
    allow(OsCtl::Lib::Cli::OutputFormatter).to receive(:print)

    command.run

    expect(OsCtl::Cli::Ps::Columns).to have_received(:generate) do |_pl, cols, _precise|
      expect(cols).to include(*OsCtl::Cli::Ps::Columns::DEFAULT_ONE_CT, :rss)
    end
  end

  it 'prints process counts and slow process reports' do
    command = cmd(opts: { parameter: [] })
    slow_proc = described_class::SlowOsProcess.new(
      double('proc', pid: 100, name: 'ruby', ct_id: [nil, nil]),
      1.5
    )
    allow(command).to receive(:get_process_list).and_return([[1, 2], {}, [slow_proc]])
    allow(OsCtl::Cli::Ps::Columns).to receive(:generate).and_return([[], []])
    allow(OsCtl::Lib::Cli::OutputFormatter).to receive(:print)

    _out, err = capture_output { command.run }

    expect(err).to include('2 processes', 'Slow processes:')
  end

  it 'filters process lists by scope and parameter filters' do
    queue = Queue.new
    command = cmd
    filter = instance_double(OsCtl::Cli::Ps::Filter, match?: true)
    matching = double('process', ct_id: %w[tank ct1], parse: nil, cmdline: 'bash')
    skipped = double('process', ct_id: %w[pond ct2])
    allow(OsCtl::Lib::ProcessList).to receive(:new) do |parse_stat:, parse_status:, &block|
      expect(parse_stat).to be(false)
      expect(parse_status).to be(false)
      [matching, skipped].select { |proc| block.call(proc) }
    end

    command.send(:list_processes, queue, { 'tank:ct1' => true }, [filter])
    result = nil
    result = queue.pop until result.is_a?(Array)

    expect(result.last).to eq('tank' => true)
    expect(result.first).to eq([matching])
  end
end
