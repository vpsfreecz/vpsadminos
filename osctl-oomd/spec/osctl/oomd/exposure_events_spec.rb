require 'spec_helper'

RSpec.describe OsCtl::Oomd::ExposureEvents do
  let(:event) { JSON.parse(File.read(File.join(__dir__, '../../fixtures/rtnl_exposure_v1.json')), symbolize_names: true) }

  it 'bounds queued and in-flight parts while a broadcast is independently blocked' do
    entered = Queue.new
    release = Queue.new
    publisher = described_class.new(notifier: lambda { |_|
      entered << true
      release.pop
    })
    publisher.start
    expect(publisher.publish([event])).to be(true)
    entered.pop
    expect(publisher.publish([event] * 63)).to be(true)
    expect(publisher.publish([event])).to be(false)
    expect(publisher.status[:rtnl_exposure_pending_parts]).to eq(64)
    64.times { release << true }
    publisher.stop
    expect(publisher.status[:rtnl_exposure_pending_parts]).to eq(0)
  end

  it 'bounds bytes, records delivery errors and continues best-effort without an acute reservation' do
    publisher = described_class.new(notifier: ->(_) { raise IOError, 'synthetic failure' })
    expect(publisher.publish([{ opts: { payload: 'x' * (1024 * 1024) } }])).to be(false)
    publisher.start
    expect(publisher.publish([event, event])).to be(true)
    publisher.stop
    expect(publisher.status).to include(rtnl_exposure_pending_parts: 0, rtnl_exposure_event_failures: 2)
  end

  it 'uses the existing node event broadcast envelope unchanged' do
    client = instance_spy(OsCtl::Client)
    allow(OsCtl::Client).to receive(:new).and_return(client)
    publisher = described_class.new
    publisher.start
    publisher.publish([event])
    publisher.stop
    expect(client).to have_received(:open)
    expect(client).to have_received(:cmd_data!).with(:event_broadcast, events: [event])
    expect(client).to have_received(:close)
    expect(publisher.status[:rtnl_exposure_event_failures]).to eq(0)
  end
end
