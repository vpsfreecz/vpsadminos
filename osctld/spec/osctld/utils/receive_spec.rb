# frozen_string_literal: true

require 'ostruct'
require 'osctld/utils/receive'

RSpec.describe OsCtld::Utils::Receive do
  let(:host) do
    Class.new do
      include OsCtld::Utils::Receive

      def error!(msg)
        raise msg
      end

      def log(*)
        nil
      end
    end.new
  end

  it 'matches authentication keys by public key' do
    key_chain_class = Class.new do
      def get_key(_name); end
    end
    pool = Struct.new(:name, :send_receive_key_chain, keyword_init: true).new(
      name: 'tank',
      send_receive_key_chain: instance_double(
        key_chain_class,
        get_key: Struct.new(:pubkey).new('pub')
      )
    )
    ct = Struct.new(:pool, :send_log, keyword_init: true).new(
      pool:,
      send_log: Struct.new(:opts).new(Struct.new(:key_name).new('used'))
    )

    stub_const('OsCtld::DB::Pools', Class.new do
      def self.find(_name); end
    end)
    allow(OsCtld::DB::Pools).to receive(:find).with('tank').and_return(pool)

    expect(host.check_auth_pubkey('tank', 'rx', ct)).to be(true)
  end

  it 'errors when the key pool does not exist' do
    stub_const('OsCtld::DB::Pools', Class.new do
      def self.find(_name); end
    end)
    allow(OsCtld::DB::Pools).to receive(:find).with('tank').and_return(nil)

    expect { host.check_auth_pubkey('tank', 'rx', Object.new) }.to raise_error('key pool not found')
  end
end
