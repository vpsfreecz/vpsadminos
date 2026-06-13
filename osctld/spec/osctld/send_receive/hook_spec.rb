# frozen_string_literal: true

load File.join(REPO_ROOT, 'osctld', 'hooks', 'send-receive')

RSpec.describe SendReceive do
  subject(:hook) do
    described_class.allocate.tap do |instance|
      instance.instance_variable_set('@client', client)
    end
  end

  let(:client) { instance_double(UNIXSocket) }

  it 'waits for the final response after progress updates' do
    allow(client).to receive(:readline).and_return(
      "#{({ status: true, progress: 'Starting container' }).to_json}\n",
      "#{({ status: true, progress: 'Waiting for the container to start' }).to_json}\n",
      "#{({ status: true, response: 'done' }).to_json}\n"
    )

    expect(hook.send(:recv_resp!)).to eq('done')
  end

  it 'reports the final error after progress updates' do
    allow(client).to receive(:readline).and_return(
      "#{({ status: true, progress: 'Starting container' }).to_json}\n",
      "#{({ status: false, message: 'container failed to start' }).to_json}\n"
    )

    expect do
      hook.send(:recv_resp!)
    end.to(
      output("Error: container failed to start\n").to_stderr.and(
        raise_error(SystemExit)
      )
    )
  end

  it 'requires the authorized key public-key hash in forced command arguments' do
    expect do
      described_class.run(argv: %w[tank chain-1-token], env: {})
    end.to(
      output("Usage: $0 <pool> <key name> <key pubkey hash>\n").to_stderr.and(
        raise_error(SystemExit)
      )
    )
  end

  it 'passes the authorized key public-key hash to cleanup commands' do
    hook.instance_variable_set('@key_pool', 'tank')
    hook.instance_variable_set('@key_name', 'chain-1-token')
    hook.instance_variable_set('@key_pubkey_hash', 'pubkey-hash')
    hook.instance_variable_set('@protocol_version', 2)
    hook.instance_variable_set('@args', ['receive-token'])

    allow(client).to receive(:puts)
    allow(client).to receive(:readline).and_return(
      "#{({ status: true, response: 'done' }).to_json}\n"
    )

    expect(hook.send(:cleanup)).to eq('done')
    expect(client).to have_received(:puts) do |payload|
      expect(JSON.parse(payload, symbolize_names: true)).to eq(
        cmd: 'receive_cleanup',
        opts: {
          key_pool: 'tank',
          key_name: 'chain-1-token',
          key_pubkey_hash: 'pubkey-hash',
          token: 'receive-token',
          protocol_version: 2
        }
      )
    end
  end

  it 'passes skeleton receive options' do
    hook.instance_variable_set('@key_pool', 'tank')
    hook.instance_variable_set('@key_name', 'chain-1-token')
    hook.instance_variable_set('@key_pubkey_hash', 'pubkey-hash')
    hook.instance_variable_set('@client_ip', '192.0.2.10')
    hook.instance_variable_set('@protocol_version', 2)
    hook.instance_variable_set('@args', %w[dst secret])

    allow(client).to receive(:puts)
    allow(client).to receive(:send_io)
    allow(client).to receive(:readline).and_return(
      "#{({ status: true, response: 'continue' }).to_json}\n",
      "#{({ status: true, response: 'token-1' }).to_json}\n"
    )

    expect do
      hook.send(:skel)
    end.to output("token-1\n").to_stdout

    expect(client).to have_received(:puts) do |payload|
      expect(JSON.parse(payload, symbolize_names: true)).to eq(
        cmd: 'receive_skel',
        opts: {
          pool: 'dst',
          passphrase: 'secret',
          client_ip: '192.0.2.10',
          key_pool: 'tank',
          key_name: 'chain-1-token',
          key_pubkey_hash: 'pubkey-hash',
          protocol_version: 2
        }
      )
    end
  end
end
