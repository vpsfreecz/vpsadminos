# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsCtl::Oomd::CtTop do
  let(:sampler) { described_class.new(15) }

  def read_stream(*records)
    data = records.map { |record| record.is_a?(String) ? record : "#{JSON.generate(record)}\n" }.join
    frames = []
    sampler.send(:read_child, StringIO.new(data)) { |frame| frames << frame }
    frames
  end

  it 'bounds and drains invalid lines, including unterminated last records' do
    stub_const('OsCtl::Oomd::CtTop::MAX_FRAME_BYTES', 64)
    frame = { 'top_schema' => 2, 'epoch' => 'a' }
    expect(read_stream("#{'x' * 100}\n", "not-json\n", frame, '{"top_schema":2,"epoch":"a"}'))
      .to eq([{}, {}, frame, {}])
  end

  it 'binds epoch to one child and rejects all other formats without fallback' do
    frame = { 'top_schema' => 2, 'epoch' => 'a' }
    changed_epoch = frame.merge('epoch' => 'b')
    expect(read_stream(frame, changed_epoch, frame)).to eq([frame, {}, frame])
    expect(read_stream(changed_epoch)).to eq([changed_epoch])
    expect(read_stream(frame.merge('top_schema' => 1), frame.merge('observation' => frame),
                       frame.except('top_schema'), frame.merge('top_schema' => 2.0), frame)).to eq([{}, {}, {}, {}, frame])
  end

  it 'requests the single default stream with all optional reads disabled' do
    frame = { 'top_schema' => 2, 'epoch' => 'a' }
    reader = StringIO.new("#{JSON.generate(frame)}\n")
    writer = instance_double(IO, close: nil)
    child = fork { exit 2 }
    stopping = Class.new(StandardError)
    allow(IO).to receive(:pipe).and_return([reader, writer])
    allow(Process).to receive(:spawn).and_return(child)
    allow(sampler).to receive(:sleep).with(5).and_raise(stopping)
    yielded = []
    expect { sampler.run { |data| yielded << data } }.to raise_error(stopping)
    expect(yielded).to eq([:child_started, frame, {}])
    expect(reader).to be_closed
    expect(Process).to have_received(:spawn).once
    expect(Process).to have_received(:spawn).with('osctl', '-j', 'ct', 'top', '--rate', '15',
                                                  '--no-netif', '--no-zfs', '--no-iostat', '--no-processes',
                                                  out: writer, close_others: true)
  end
end
