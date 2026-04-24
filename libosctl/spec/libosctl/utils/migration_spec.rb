# frozen_string_literal: true

require 'spec_helper'
require 'libosctl/utils/migration'

RSpec.describe OsCtl::Lib::Utils::Send do
  before do
    stub_const('TestKeyChain', Class.new)
  end

  let(:helper_class) do
    Class.new do
      include OsCtl::Lib::Utils::Send
    end
  end

  let(:helper) { helper_class.new }

  let(:machine_opts) do
    {
      dst: 'node.example.test',
      port: 2222
    }
  end

  it 'builds ssh commands with and without a key chain' do
    key_chain = instance_double(TestKeyChain, private_key_path: '/tmp/key')

    expect(helper.send_ssh_cmd(key_chain, machine_opts, %w[echo hello])).to eq(
      [
        'ssh',
        '-o', 'StrictHostKeyChecking=no',
        '-T',
        '-p', '2222',
        '-i', '/tmp/key',
        '-l', 'osctl-ct-receive',
        'node.example.test',
        'echo', 'hello'
      ]
    )

    expect(helper.send_ssh_cmd(nil, machine_opts, %w[echo hello])).to eq(
      [
        'ssh',
        '-o', 'StrictHostKeyChecking=no',
        '-T',
        '-p', '2222',
        '-l', 'osctl-ct-receive',
        'node.example.test',
        'echo', 'hello'
      ]
    )
  end

  it 'injects the send/receive protocol version into receive commands' do
    expect(
      helper.send_ssh_cmd(
        nil,
        machine_opts.merge(protocol_version: 2),
        %w[receive transfer token-1]
      )
    ).to eq(
      [
        'ssh',
        '-o', 'StrictHostKeyChecking=no',
        '-T',
        '-p', '2222',
        '-l', 'osctl-ct-receive',
        'node.example.test',
        'receive', '2', 'transfer', 'token-1'
      ]
    )
  end

  it 'requires the send/receive protocol version for receive commands' do
    expect do
      helper.send_ssh_cmd(nil, machine_opts, %w[receive transfer token-1])
    end.to raise_error(ArgumentError, 'send/receive protocol version not provided')
  end
end
