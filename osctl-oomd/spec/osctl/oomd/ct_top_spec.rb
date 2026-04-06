# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsCtl::Oomd::CtTop do
  it 'yields valid JSON lines, skips malformed input, and logs process exit' do
    ct_top = described_class.new(15)
    reader = instance_double(IO)
    writer = instance_double(IO, close: nil)
    child_pid = fork { exit 7 }
    stop_error = Class.new(StandardError)
    logged = []

    allow(IO).to receive(:pipe).and_return([reader, writer])
    allow(Process).to receive(:spawn).and_return(child_pid)
    allow(ct_top).to receive(:sleep).and_raise(stop_error)
    allow(OsCtl::Lib::Logger).to receive(:log) do |level, message|
      logged << [level, message]
    end
    allow(reader).to receive(:eof?).and_return(false, false, false, true)
    allow(reader).to receive(:readline).and_return(
      "{\"id\":\"ct1\"}\n",
      "not-json\n",
      "{\"id\":\"ct2\"}\n"
    )

    yielded = []

    expect do
      ct_top.run { |data| yielded << data }
    end.to raise_error(stop_error)

    expect(yielded).to eq([{ 'id' => 'ct1' }, { 'id' => 'ct2' }])
    expect(logged.any? { |level, message| level == :warn && message.include?('Unable to parse output') }).to be(true)
    expect(logged.any? { |level, message| level == :info && message == "[ct-top] Started with pid #{child_pid}" }).to be(true)
    expect(logged.any? { |level, message| level == :info && message == '[ct-top] Exited with pid 7' }).to be(true)
  end
end
