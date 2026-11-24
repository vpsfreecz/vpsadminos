# frozen_string_literal: true

require 'spec_helper'
require 'timeout'

RSpec.describe OsCtl::Oomd::Evidence do
  def wait_for(&block)
    Timeout.timeout(2) { Thread.pass until block.call }
  end

  it 'retains partial writes, EINTR, EAGAIN and errors in exact stream order' do
    output = +''
    attempts = 0
    writer = lambda do |bytes|
      attempts += 1
      case attempts
      when 1
        output << bytes.byteslice(0, 7)
        7
      when 2 then raise Errno::EINTR
      when 3 then :wait_writable
      when 4 then raise IOError, 'fixture failure'
      else
        output << bytes
        bytes.bytesize
      end
    end
    evidence = described_class.new(writer:)
    evidence.start
    ticket = evidence.reserve(2)
    evidence.batch(evidence.frame('one') + evidence.frame('two'), ticket)
    wait_for { evidence.status[:evidence_pending_records] == 0 }
    rows = output.lines.map { |line| JSON.parse(line) }
    expect(rows.map { |r| r['type'] }).to eq(%w[one two])
    expect(rows.map { |r| r['event_sequence'] }).to eq([1, 2])
    expect(evidence.status[:evidence_failures]).to eq(1)
  ensure
    evidence&.stop
  end

  it 'round-trips long UTF8 fields as numbered complete fragments below3072 bytes' do
    output = +''
    evidence = described_class.new(writer: lambda { |bytes|
      output << bytes
      bytes.bytesize
    })
    fields = { message: 'ž' * 6000, sample_epoch: 'e', sample_sequence: 1 }
    fragments = evidence.frame('container', fields)
    expect(fragments.size).to be > 1
    evidence.batch(fragments, evidence.reserve(fragments.size))
    evidence.start
    evidence.stop
    rows = output.lines.map { |line| JSON.parse(line) }
    expect(output.lines.map(&:bytesize).max).to be <= 3072
    expect(rows.map { |r| r['part'] }).to eq((1..rows.size).to_a)
    expect(rows.map { |r| r['parts'] }.uniq).to eq([rows.size])
    raw = Base64.strict_decode64(rows.map { |r| r['data'] }.join)
    expect(raw.bytesize).to eq(rows.first['original_bytes'])
    expect(JSON.parse(raw)).to include('message' => fields[:message], 'type' => 'container')
    expect(rows[0...-1].size).not_to eq(rows.first['parts']) # A missing end is incomplete.
  end

  it 'drains a real initially full nonblocking pipe without evicting the accepted head' do
    reader, writer = IO.pipe
    loop do
      result = writer.write_nonblock('x' * 4096, exception: false)
      break if result == :wait_writable
    end
    evidence = described_class.new(writer: ->(bytes) { writer.write_nonblock(bytes, exception: false) })
    evidence.batch(evidence.frame('pipe_head'), evidence.reserve(1))
    evidence.start
    expect(evidence.status[:evidence_pending_records]).to eq(1)
    received = +''
    Timeout.timeout(2) do
      loop do
        result = reader.read_nonblock(8192, exception: false)
        received << result if result.is_a?(String)
        break if received.include?("\n")

        Thread.pass
      end
    end
    wait_for { evidence.status[:evidence_pending_records] == 0 }
    expect(JSON.parse(received[received.index('{')..])['type']).to eq('pipe_head')
  ensure
    evidence&.stop
    reader&.close
    writer&.close
  end

  it 'counts reservations and the blocked writer, preserving shutdown until acceptance' do
    release = false
    output = +''
    evidence = described_class.new(writer: lambda { |bytes|
      next :wait_writable unless release

      output << bytes
      bytes.bytesize
    })
    reserved = evidence.reserve(504)
    expect(evidence.reserve(1)).to be_nil
    evidence.batch(evidence.frame('accepted'), reserved)
    evidence.start
    wait_for { evidence.status[:evidence_pending_records] == 1 }
    stop = Thread.new { evidence.stop }
    expect(stop.join(0.02)).to be_nil
    expect(evidence.status[:evidence_records]).to eq(9)
    release = true
    expect(stop.join(2)).to eq(stop)
    expect(JSON.parse(output)['type']).to eq('accepted')
  ensure
    release = true
    stop&.join(2)
  end
end
