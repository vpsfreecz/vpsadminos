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
end
