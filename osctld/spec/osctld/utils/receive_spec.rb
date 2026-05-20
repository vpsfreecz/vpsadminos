# frozen_string_literal: true

require 'digest'
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

  it 'matches authentication keys by public-key hash' do
    key_chain_class = Class.new do
      def get_key(_name); end
    end
    pool = Struct.new(:name, :send_receive_key_chain).new(
      'tank',
      instance_double(
        key_chain_class,
        get_key: Struct.new(:pubkey).new('pub')
      )
    )
    ct = Struct.new(:pool, :send_log).new(
      pool,
      Struct.new(:opts).new(Struct.new(:key_name).new('used'))
    )

    expect(
      host.check_auth_pubkey(
        'tank',
        'rx',
        ct,
        key_pubkey_hash: Digest::SHA256.hexdigest('pub')
      )
    ).to be(true)
  end

  it 'matches authentication by public key hash when the selected key name was removed' do
    key_chain_class = Class.new do
      def get_key(_name); end
    end
    used_key = Struct.new(:pubkey).new('pub')
    pool = Struct.new(:name, :send_receive_key_chain).new(
      'tank',
      instance_double(
        key_chain_class,
        get_key: used_key
      )
    )
    ct = Struct.new(:pool, :send_log).new(
      pool,
      Struct.new(:opts).new(Struct.new(:key_name).new('used'))
    )

    expect(
      host.check_auth_pubkey(
        'tank',
        'removed',
        ct,
        key_pubkey_hash: Digest::SHA256.hexdigest('pub')
      )
    ).to be(true)
  end

  it 'rejects authentication without a public-key hash' do
    expect(
      host.check_auth_pubkey(
        'tank',
        'rx',
        Object.new,
        key_pubkey_hash: nil
      )
    ).to be(false)
  end
end
