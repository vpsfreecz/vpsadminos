# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsCtl::Cli::Debug do
  def cmd(args: [], opts: {}, gopts: {})
    build_command(described_class, args:, opts:, gopts:)
  end

  let(:locks) do
    [
      {
        id: 1,
        thread: 'thr',
        object: 'obj',
        type: 'exclusive',
        state: 'held',
        time: 10,
        backtrace: %w[a b]
      }
    ]
  end

  it 'formats lock listings in compact and verbose modes' do
    compact = cmd
    verbose = cmd(opts: { verbose: true })
    allow(compact).to receive(:osctld_call).and_return(locks.map(&:dup))
    allow(verbose).to receive(:osctld_call).and_return(locks.map(&:dup))
    allow(compact).to receive(:format_output)
    allow(verbose).to receive(:format_output)

    compact.locks_ls
    verbose.locks_ls

    expect(compact).to have_received(:format_output).with(kind_of(Array), cols: %i[id thread object type state], layout: :columns)
    expect(verbose).to have_received(:format_output) do |data, cols:, layout:|
      expect(cols).to eq(%i[id time thread object type state backtrace])
      expect(layout).to eq(:rows)
      expect(data.first[:backtrace]).to eq("a\nb")
    end
  end

  it 'shows a lock by id and formats thread backtraces' do
    show = cmd(args: ['1'])
    threads = cmd
    allow(show).to receive(:osctld_call).and_return(locks.map(&:dup))
    allow(threads).to receive(:osctld_call).and_return([{ backtrace: %w[x y] }])
    allow(show).to receive(:format_output)
    allow(threads).to receive(:format_output)

    show.locks_show
    threads.threads_ls

    expect(show).to have_received(:format_output).with(hash_including(backtrace: "a\nb"))
    expect(threads).to have_received(:format_output).with([hash_including(backtrace: "x\ny")], layout: :rows)
  end

  it 'lists ugids in all, taken, and free modes and rejects invalid choices' do
    command = cmd(args: ['all'])
    allow(command).to receive(:osctld_call).and_return(allocated: [1], free: [2])

    out, = capture_output { command.ugids_ls }
    expect(out).to include('1', '2')

    taken = cmd(args: ['taken'])
    allow(taken).to receive(:osctld_call).and_return(allocated: [1], free: [2])
    out, = capture_output { taken.ugids_ls }
    expect(out).to eq("1\n")

    free = cmd(args: ['free'])
    allow(free).to receive(:osctld_call).and_return(allocated: [1], free: [2])
    out, = capture_output { free.ugids_ls }
    expect(out).to eq("2\n")

    invalid = cmd(args: ['bad'])
    allow(invalid).to receive(:osctld_call).and_return(allocated: [], free: [])
    expect { invalid.ugids_ls }.to raise_error(GLI::BadCommandLine)
  end
end
