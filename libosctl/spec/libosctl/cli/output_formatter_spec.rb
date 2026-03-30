# frozen_string_literal: true

require 'spec_helper'
require 'rainbow'
require 'libosctl/cli/presentable'
require 'libosctl/cli/output_formatter'

RSpec.describe 'OsCtl::Lib::Cli::OutputFormatter' do
  let(:formatter_class) { OsCtl::Lib::Cli::OutputFormatter }

  it 'auto-selects column layout for multiple objects' do
    output = formatter_class.to_s(
      [
        { id: 1, name: 'alpha' },
        { id: 2, name: 'beta' }
      ]
    )

    expect(output).to eq(<<~OUT)
      ID   NAME
      1    alpha
      2    beta
    OUT
  end

  it 'auto-selects row layout for a single object and keeps multiline values aligned' do
    output = formatter_class.to_s({ id: 1, note: "line one\nline two" })

    expect(output).to eq("   ID:  1\n NOTE:  line one\n        line two\n\n")
  end

  it 'supports explicit column settings, alignment, hidden headers, and empty placeholders' do
    output = formatter_class.to_s(
      [{ count: 7, name: nil }],
      cols: [
        { name: :count, label: 'COUNT', align: 'right' },
        { name: :name, label: 'NAME' }
      ],
      header: false,
      empty: '(none)',
      layout: :columns
    )

    expect(output).to eq("     7  (none)\n")
  end

  it 'sorts by selected columns and sorts presentable values by raw value' do
    objects = [
      { id: 2, memory: OsCtl::Lib::Cli::Presentable.new(10, formatted: 'ten') },
      { id: 1, memory: OsCtl::Lib::Cli::Presentable.new(2, formatted: 'two') }
    ]

    output = formatter_class.to_s(objects, sort: %i[memory id])

    expect(output.lines[1]).to include("1    two\n")
    expect(output.lines[2]).to include("2    ten\n")
  end

  it 'handles ANSI colors when calculating widths and prints to stdout' do
    objects = [
      { state: Rainbow('RUNNING').green, name: 'alpha' },
      { state: 'STOPPED', name: 'bravo' }
    ]

    output = capture_stdout do
      formatter_class.print(objects, color: true)
    end

    plain_lines = output.lines.map { |line| Rainbow::StringUtils.uncolor(line.chomp) }

    expect(plain_lines[1].length).to eq(plain_lines[2].length)
  end
end
