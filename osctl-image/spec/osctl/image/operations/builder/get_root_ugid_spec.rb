# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsCtl::Image::Operations::Builder::GetRootUgid do
  let(:builder) { instance_double(OsCtl::Image::Builder, ctid: 'builder-1') }
  let(:client) { instance_double(OsCtl::Image::OsCtldClient) }

  before do
    allow(OsCtl::Image::OsCtldClient).to receive(:new).and_return(client)
    allow(client).to receive(:batch).and_yield(client)
    allow(client).to receive(:find_container).with('builder-1').and_return(user: 'builder-user')
  end

  it 'returns the host uid and gid for namespace root' do
    allow(client).to receive(:user_idmap).with('builder-user').and_return(
      [
        { type: 'uid', ns_id: 0, host_id: 100_000 },
        { type: 'gid', ns_id: 0, host_id: 200_000 }
      ]
    )

    expect(described_class.new(builder).execute).to eq([100_000, 200_000])
  end

  it 'raises when root uid or gid mappings are missing' do
    allow(client).to receive(:user_idmap).with('builder-user').and_return(
      [{ type: 'uid', ns_id: 1, host_id: 100_000 }]
    )

    expect { described_class.new(builder).execute }
      .to raise_error(OsCtl::Image::OperationError, 'unable to find root uid in id map')
  end
end
