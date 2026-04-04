# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsCtl::Console do
  let(:socket) { FakeSocketHelpers::NonblockIODouble.new }
  let(:input) { FakeSocketHelpers::NonblockIODouble.new }
  let(:output) { StringIO.new }

  it 'sends raw input bytes directly to the socket' do
    raw_input = FakeSocketHelpers::NonblockIODouble.new(['abc'])
    console = described_class.new(socket, raw_input, output, raw: true)

    console.send(:read_in)

    expect(socket.writes).to eq(['abc'])
  end

  it 'wraps non-raw keyboard input in json commands' do
    cooked_input = FakeSocketHelpers::NonblockIODouble.new(['ab'])
    console = described_class.new(socket, cooked_input, output)

    console.send(:read_in)

    expect(socket.writes).to eq(["{\"keys\":\"YWI=\"}\n"])
  end

  it 'buffers partial detach prefixes until the next input chunk' do
    cooked_input = FakeSocketHelpers::NonblockIODouble.new(["\x01", 'x'])
    console = described_class.new(socket, cooked_input, output)

    console.send(:read_in)
    expect(socket.writes).to eq(["{\"keys\":\"\"}\n"])

    console.send(:read_in)
    expect(socket.writes.last).to eq("{\"keys\":\"AXg=\"}\n")
  end

  it 'closes the socket and stops on Ctrl+a q' do
    cooked_input = FakeSocketHelpers::NonblockIODouble.new(["\x01q"])
    console = described_class.new(socket, cooked_input, output)

    expect(console.send(:read_in)).to eq(:stop)
    expect(socket).to be_closed
  end

  it 'sends resize commands as json' do
    console = described_class.new(socket, input, output)

    console.resize(25, 80)

    expect(socket.writes).to eq(["{\"rows\":25,\"cols\":80}\n"])
  end

  it 'forwards socket output to the terminal and stops on IOError' do
    readable_socket = FakeSocketHelpers::NonblockIODouble.new(['hello', IOError.new('closed')])
    console = described_class.new(readable_socket, input, output)

    allow(IO).to receive(:select).and_return([[readable_socket]], [[readable_socket]])

    console.open

    expect(output.string).to eq('hello')
  end
end
