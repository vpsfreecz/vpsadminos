# frozen_string_literal: true

require 'osctld/send_receive/tokens'

RSpec.describe OsCtld::SendReceive::Tokens do
  subject(:tokens) { described_class.send(:new) }

  let(:containers_class) do
    Class.new do
      def self.get
        []
      end
    end
  end

  before do
    stub_const('OsCtld::DB::Containers', containers_class)
  end

  it 'allocates unique tokens' do
    allow(SecureRandom).to receive(:hex).and_return('token-1')

    token = tokens.get

    expect(token).to eq('token-1')
    expect { tokens.register('token-1') }.to raise_error(RuntimeError, /already in use/)
  end

  it 'retries duplicate generated tokens' do
    tokens.register('dup')
    allow(SecureRandom).to receive(:hex).and_return('dup', 'fresh')

    expect(tokens.get).to eq('fresh')
  end

  it 'raises when duplicate token generation is exhausted' do
    tokens.register('dup')
    allow(SecureRandom).to receive(:hex).and_return(*Array.new(10, 'dup'))

    expect { tokens.get }.to raise_error(RuntimeError, 'unable to generate a unique token')
  end

  it 'raises when registering duplicate tokens' do
    tokens.register('token-1')

    expect { tokens.register('token-1') }.to raise_error(RuntimeError, /already in use/)
  end

  it 'frees tokens' do
    tokens.register('token-1')
    tokens.free('token-1')

    expect { tokens.register('token-1') }.not_to raise_error
  end

  it 'finds matching containers by send log token' do
    token = 'token-1'
    send_log = Struct.new(:token).new(token)
    container = FakeObjects::FakeDbObject.new(
      id: '100',
      pool: FakeObjects::FakeNamed.new('tank'),
      send_log: send_log
    )

    allow(OsCtld::DB::Containers).to receive(:get).and_return([container])
    tokens.register(token)

    expect(tokens.find_container(token)).to eq(container)
  end

  it 'returns nil when token is not present' do
    expect(tokens.find_container('missing')).to be_nil
  end
end
